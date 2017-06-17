open Lwt.Infix
open Sexplib.Std

let superblock_magic = "MIRAGE KVFS \xf0\x9f\x90\xaa"
let superblock_version = 1l
let max_dirty = 128


exception BadMagic
exception BadVersion
exception BadFlags
exception BadCRC of int64
exception BadParams

exception ReadError
exception WriteError
exception OutOfSpace
exception NeedsFlush

exception BadKey of Cstruct.t
exception ValueTooLarge of Cstruct.t
exception BadNodeType of int

(* 512 bytes.  The rest of the block isn't crc-controlled. *)
[%%cstruct type superblock = {
  magic: uint8_t [@len 16];
  (* major version, all later fields may change if this does *)
  version: uint32_t;
  compat_flags: uint32_t;
  (* refuse to mount if unknown incompat_flags are set *)
  incompat_flags: uint32_t;
  block_size: uint32_t;
  key_size: uint8_t;
  first_block_written: uint64_t;
  logical_size: uint64_t;
  reserved: uint8_t [@len 459];
  crc: uint32_t;
}[@@little_endian]]

let () = assert (String.length superblock_magic = 16)
let () = assert (sizeof_superblock = 512)

let sizeof_crc = 4

[%%cstruct type anynode_hdr = {
  nodetype: uint8_t;
  generation: uint64_t;
}[@@little_endian]]
let () = assert (sizeof_anynode_hdr = 9)

[%%cstruct type rootnode_hdr = {
  (* nodetype = 1 *)
  nodetype: uint8_t;
  (* will this wrap? there's no uint128_t. Nah, flash will wear out first. *)
  generation: uint64_t;
}[@@little_endian]]
(* Contents: logged data, and child node links *)
(* All node types end with a CRC *)
(* rootnode_hdr
 * logged data: (key, datalen, data)*, grow from the left end towards the right
 *
 * separation: at least at redzone_size (the largest of a key or a uint64_t) of all zeroes
 * disambiguates from a valid logical offset on the right,
 * disambiguates from a valid key on the left.
 *
 * child links: (key, logical offset)*, grow from the right end towards the left
 * crc *)

[%%cstruct type childnode_hdr = {
  (* nodetype = 2 *)
  nodetype: uint8_t;
  generation: uint64_t;
}[@@little_endian]]
(* Contents: logged data, and child node links *)
(* Layout: see above *)

let sizeof_datalen = 2

let sizeof_logical = 8

let rec make_fanned_io_list size cstr =
  if Cstruct.len cstr = 0 then []
  else let head, rest = Cstruct.split cstr size in
  head::make_fanned_io_list size rest

type statistics = {
  mutable inserts: int;
  mutable lookups: int;
  mutable range_searches: int;
}

let default_statistics = {
  inserts=0;
  lookups=0;
  range_searches=0;
}

type childlinks = {
  (* starts at block_size - sizeof_crc, if there are no children *)
  mutable childlinks_offset: int;
}

type keydata_index = {
  (* in descending order. if the list isn't empty,
   * last item must be sizeof_*node_hdr *)
  mutable keydata_offsets: int list;
  mutable next_keydata_offset: int;
}

(* Use offsets so that data isn't duplicated
 * Don't reference nodes directly, always go through the
 * LRU to bump recently accessed nodes *)
type childlink_entry = {
  offset: int; (* logical is at offset + P.key_size *)
  mutable alloc_id: int64 option;
} (*[@@deriving sexp]*)

let sexp_of_childlink_entry { offset; _ } =
Sexplib.Sexp.List [Sexplib.Sexp.Atom "offset"; sexp_of_int offset]

type node = [
  |`Root
  |`Child]

let is_root = function
  |`Root -> true
  |_ -> false

let type_code = function
  |`Root -> 1
  |`Child -> 2

let header_size = function
  |`Root -> sizeof_rootnode_hdr
  |`Child -> sizeof_childnode_hdr

let check_node_type = function
  |1|2 -> ()
  |ty -> raise @@ BadNodeType ty

let string_dump key =
  Cstruct.hexdump @@ Cstruct.of_string key

module KeyedMap = Map_pr869.Make(String)
module KeyedSet = Set.Make(String)

module LRUKey = struct
  type t = int64
  let compare = Int64.compare
  let hash = Hashtbl.hash
  let equal = Int64.equal
end

type flush_info = {
  mutable flush_children: LRUKey.t KeyedMap.t;
}

type lru_entry = {
  cached_node: node;
  mutable parent_key: LRUKey.t option;
  (* A node is flushable iff it's referenced from flush_root
     through a flush_children map.
     We use an option here to make checking for flushability faster.
     A flushable node is either new or dirty, but not both. *)
  mutable flush_info: flush_info option;
  mutable children: childlink_entry KeyedMap.t Lazy.t;
  mutable logindex: int KeyedMap.t Lazy.t;
  mutable highest_key: string;
  raw_node: Cstruct.t;
  io_data: Cstruct.t list;
  keydata: keydata_index;
  childlinks: childlinks;
  mutable prev_logical: int64 option;
}

module LRUValue = struct
  type t = lru_entry
  let weight _val = 1
end

let generation_of_node entry =
  get_anynode_hdr_generation entry.raw_node

module LRU = Lru.M.Make(LRUKey)(LRUValue)

let lru_get lru alloc_id =
  LRU.find alloc_id lru

let lru_peek lru alloc_id =
  LRU.find ~promote:false alloc_id lru

exception AlreadyCached of LRUKey.t

let lookup_parent_link lru entry =
  match entry.parent_key with
  |None -> None
  |Some parent_key ->
    match lru_peek lru parent_key with
    |None -> failwith "Missing parent"
    |Some parent_entry ->
    let children = Lazy.force parent_entry.children in
    let cl = KeyedMap.find entry.highest_key children in
    Some (parent_key, parent_entry, cl)

let lru_xset lru alloc_id value =
  if LRU.mem alloc_id lru then raise @@ AlreadyCached alloc_id;
  let would_discard = ((LRU.size lru) + (LRUValue.weight value) > LRU.capacity lru) in
  (* assumes uniform weights, looks only at the bottom item *)
  if would_discard then begin
    match LRU.lru lru with
    |Some (_alloc_id, entry) when entry.flush_info <> None ->
      failwith "Would discard dirty data" (* TODO expose this as a proper API value *)
    |Some (_alloc_id, entry) ->
      begin match lookup_parent_link lru entry with
      |None -> failwith "Would discard a root key, LRU too small for tree depth"
      |Some (_parent_key, _parent_entry, cl) ->
        cl.alloc_id <- None
      end
    |_ -> failwith "LRU capacity is too small"
  end;
  LRU.add alloc_id value lru

let lru_create capacity =
  LRU.create capacity

type node_cache = {
  (* LRUKey.t -> lru_entry
   * all nodes are keyed by their alloc_id *)
  lru: LRU.t;
  mutable flush_root: LRUKey.t option;
  mutable next_alloc_id: int64;
  (* The next generation number we'll allocate *)
  mutable next_generation: int64;
  (* The next logical address we'll allocate (if free) *)
  mutable next_logical_alloc: int64;
  (* Count of free blocks on disk *)
  mutable free_count: int64;
  mutable new_count: int64;
  mutable dirty_count: int64;
  logical_size: int64;
  (* Logical -> bit.  Zero iff free. *)
  space_map: Bitv.t;
  statistics: statistics;
}

let bitv_create64 off bit =
  if Int64.compare off (Int64.of_int max_int) > 0 then failwith (Printf.sprintf "Size %Ld too large for a Bitv" off);
  Bitv.create (Int64.to_int off) bit

let bitv_set64 vec off bit =
  Bitv.set vec (Int64.to_int off) bit (* Safe as long as bitv_create64 is used *)

let bitv_get64 vec off =
  Bitv.get vec (Int64.to_int off) (* Safe as long as bitv_create64 is used *)

let bitv_len64 vec =
  Int64.of_int @@ Bitv.length vec

let next_logical_novalid cache logical =
  let log1 = Int64.succ logical in
  if log1 = cache.logical_size then 1L else log1

let next_logical_alloc_valid cache =
  if cache.free_count = 0L then raise OutOfSpace;
  let rec after log =
    if not @@ bitv_get64 cache.space_map log then log else
      after @@ next_logical_novalid cache log
  in let loc = after cache.next_logical_alloc in
  cache.next_logical_alloc <- next_logical_novalid cache loc; loc

let next_alloc_id cache =
  let r = cache.next_alloc_id in
  cache.next_alloc_id <- Int64.succ cache.next_alloc_id;
  r

let next_generation cache =
  let r = cache.next_generation in
  cache.next_generation <- Int64.succ cache.next_generation;
  r

let int64_pred_nowrap va =
  if Int64.compare va 0L <= 0 then failwith "Wrapped"
  else Int64.pred va

type insertable =
  |InsValue of Cstruct.t
  |InsChild of int64 * int64 option (* loc, alloc_id *)
  (*|InsTombstone*) (* use empty values for now *)


let rec _mark_dirty cache alloc_id : flush_info =
  (*Logs.info (fun m -> m "_mark_dirty");*)
  match lru_get cache.lru alloc_id with
  |None -> failwith "Missing LRU key"
  |Some entry -> begin
      match entry.flush_info with
      |None -> begin
          match entry.cached_node with
          |`Root ->
            begin match cache.flush_root with
              |None -> cache.flush_root <- Some alloc_id
              |_ -> failwith "flush_root inconsistent" end
          |`Child ->
            match entry.parent_key with
            |Some parent_key -> begin
                match lru_get cache.lru parent_key with
                |None -> failwith "missing parent_entry"
                |Some _parent_entry ->
                    let parent_di = _mark_dirty cache parent_key in
                    begin
                      match KeyedMap.filter (fun _k lk -> lk = alloc_id) parent_di.flush_children with
                      |m when m = KeyedMap.empty -> begin parent_di.flush_children <- KeyedMap.add entry.highest_key alloc_id parent_di.flush_children end
                      |_ -> failwith "dirty_node inconsistent" end
              end
            |None -> failwith "entry.parent_key inconsistent (no parent)";
        end;
        let di = { flush_children=KeyedMap.empty; } in
        entry.flush_info <- Some di;
        begin
        match entry.prev_logical with
        |None ->
          let nc1 = Int64.succ cache.new_count in
          if Int64.(compare (add nc1 cache.dirty_count) cache.free_count) > 0 then raise OutOfSpace;
          cache.new_count <- nc1;
        |Some _plog ->
          let dc1 = Int64.succ cache.dirty_count in
          if Int64.(compare (add dc1 cache.new_count) cache.free_count) > 0 then raise NeedsFlush;
          cache.dirty_count <- dc1;
        end;
        di
      |Some di -> di
    end

exception RangeEnd

(* The range where start_cond and not end_cond *)
let csm_iter_range start_cond end_cond it csm =
  try
    KeyedMap.iter_from_first
      start_cond
      (fun k v -> if end_cond k then raise RangeEnd;
        it k v)
      csm
  with
  |RangeEnd -> ()

(* As above, but include one element past the end *)
let csm_iter_range_plus start_cond end_cond it csm =
  let after_end = ref false in
  try
    KeyedMap.iter_from_first
      start_cond
      (fun k v -> if end_cond k then begin
           if !after_end then raise RangeEnd else after_end := true end;
         it k v)
      csm
  with
  |RangeEnd -> ()

let _get_superblock_io () =
  (* This will only work on Unix, which has buffered IO instead of direct IO.
  TODO figure out portability *)
    Cstruct.create 512

module type PARAMS = sig
  (* in bytes *)
  val block_size: int
  (* in bytes *)
  val key_size: int
end

module StandardParams : PARAMS = struct
  let block_size = 256*1024
  let key_size = 20;
end

type deviceOpenMode =
  |OpenExistingDevice
  |FormatEmptyDevice of int64

module type S = sig
  type key
  type value
  type disk
  type root

  val key_of_cstruct : Cstruct.t -> key
  val cstruct_of_key : key -> Cstruct.t
  val value_of_cstruct : Cstruct.t -> value
  val cstruct_of_value : value -> Cstruct.t

  val insert : root -> key -> value -> unit Lwt.t
  val lookup : root -> key -> value Lwt.t
  val flush : root -> int64 Lwt.t
  val log_statistics : root -> unit
  val search_range : root
    -> (key -> bool)
    -> (key -> bool)
    -> (key -> unit)
    -> unit Lwt.t
  val prepare_io : deviceOpenMode -> disk -> int -> (root * int64) Lwt.t
end

module Make(B: Mirage_types_lwt.BLOCK)(P: PARAMS) : (S with type disk = B.t) = struct
  type key = string
  type value = Cstruct.t
  type disk = B.t

  module P = P

  let key_of_cstruct key =
    if Cstruct.len key <> P.key_size
    then raise @@ BadKey key
    else Cstruct.to_string key

  let cstruct_of_key key =
    Cstruct.of_string key

  let value_of_cstruct value =
    let len = Cstruct.len value in
    if len >= 65536 then raise @@ ValueTooLarge value else value

  let cstruct_of_value value = value

  let block_end = P.block_size - sizeof_crc

  let _get_block_io () =
    if P.block_size >= Io_page.page_size then
      Io_page.get_buf ~n:(P.block_size/Io_page.page_size) ()
    else (* This will only work on Unix, which has buffered IO instead of direct IO.
            Allows more efficient fuzzing. *)
      Cstruct.create P.block_size

  let zero_key = String.make P.key_size '\000'
  let top_key = String.make P.key_size '\255'
  let zero_data = Cstruct.create P.block_size
  let is_zero_key cstr =
    String.equal cstr zero_key
  let _is_zero_data cstr =
    Cstruct.equal cstr zero_data

  let redzone_size = max P.key_size sizeof_logical

  let childlink_size = P.key_size + sizeof_logical

  type filesystem = {
    (* Backing device *)
    disk: B.t;
    (* The exact size of IO the BLOCK accepts.
     * Even larger powers of two won't work *)
    (* 4096 with unbuffered target=unix, 512 with virtualisation *)
    sector_size: int;
    (* the sector size that's used for the write offset *)
    other_sector_size: int;
  }

  type open_fs = {
    filesystem: filesystem;
    node_cache: node_cache;
  }

  let _load_data_at filesystem logical =
    Logs.info (fun m -> m "_load_data_at %Ld" logical);
    let cstr = _get_block_io () in
    let io_data = make_fanned_io_list filesystem.sector_size cstr in
    B.read filesystem.disk Int64.(div (mul logical @@ of_int P.block_size) @@ of_int filesystem.other_sector_size) io_data >>= Lwt.wrap1 begin function
      |Result.Error _ -> raise ReadError
      |Result.Ok () ->
          if not @@ Crc32c.cstruct_valid cstr
          then raise @@ BadCRC logical
          else cstr, io_data end

  let _find_childlinks_offset cstr =
    let rec scan off poff =
        let log1 = Cstruct.LE.get_uint64 cstr (off + P.key_size) in
        if log1 <> 0L then scan (off - childlink_size) off else poff
    in scan (block_end - childlink_size) block_end

  (* build a keydata_index *)
  let _index_keydata cstr hdrsize =
    Logs.info (fun m -> m "_index_keydata");
    let r = {
      keydata_offsets=[];
      next_keydata_offset=hdrsize;
    } in
    let rec scan off =
      if is_zero_key @@ Cstruct.to_string @@ Cstruct.sub cstr off P.key_size then () else begin
        r.keydata_offsets <- off::r.keydata_offsets;
        r.next_keydata_offset <- off + P.key_size + sizeof_datalen + (Cstruct.LE.get_uint16 cstr (off + P.key_size));
        scan r.next_keydata_offset;
      end
    in scan hdrsize; r

  let rec _gen_childlink_offsets start =
    if start >= block_end then []
    else start::(_gen_childlink_offsets @@ start + childlink_size)

  let _compute_children entry =
    Logs.info (fun m -> m "_compute_children");
    List.fold_left (
      fun acc off ->
        let key = Cstruct.to_string @@ Cstruct.sub (
          entry.raw_node) off P.key_size in
        KeyedMap.add key {offset=off; alloc_id=None} acc)
      KeyedMap.empty (_gen_childlink_offsets entry.childlinks.childlinks_offset)

  (* Needs an up to date _index_keydata *)
  let _compute_keydata entry =
    (*Logs.info (fun m -> m "_compute_keydata");*)
    let kd = entry.keydata in
    List.fold_left (
      fun acc off ->
        let key = Cstruct.to_string @@ Cstruct.sub
          entry.raw_node off P.key_size in
        KeyedMap.add key off acc)
      KeyedMap.empty kd.keydata_offsets

  let _load_root_node_at open_fs logical =
    Logs.info (fun m -> m "_load_root_node_at");
    let%lwt cstr, io_data = _load_data_at open_fs.filesystem logical in
    let cache = open_fs.node_cache in
    assert (Cstruct.len cstr = P.block_size);
      let cached_node, keydata =
      match get_anynode_hdr_nodetype cstr with
      |1 -> `Root, _index_keydata cstr sizeof_rootnode_hdr
      |ty -> raise @@ BadNodeType ty
    in
      let alloc_id = next_alloc_id cache in
    let rec entry = {parent_key=None; cached_node; raw_node=cstr; io_data; keydata; flush_info=None; children=lazy (_compute_children entry); logindex=lazy (_compute_keydata entry); highest_key=top_key; prev_logical=Some logical; childlinks={childlinks_offset=_find_childlinks_offset cstr;}} in
      lru_xset cache.lru alloc_id entry;
      Lwt.return (alloc_id, entry)

  let _load_child_node_at open_fs logical highest_key parent_key =
    Logs.info (fun m -> m "_load_child_node_at");
    let%lwt cstr, io_data = _load_data_at open_fs.filesystem logical in
    let cache = open_fs.node_cache in
    assert (Cstruct.len cstr = P.block_size);
      let cached_node, keydata =
      match get_anynode_hdr_nodetype cstr with
      |2 -> `Child, _index_keydata cstr sizeof_childnode_hdr
      |ty -> raise @@ BadNodeType ty
    in
      let alloc_id = next_alloc_id cache in
    let rec entry = {parent_key=Some parent_key; cached_node; raw_node=cstr; io_data; keydata; flush_info=None; children=lazy (_compute_children entry); logindex=lazy (_compute_keydata entry); highest_key; prev_logical=Some logical; childlinks={childlinks_offset=_find_childlinks_offset cstr;}} in
      lru_xset cache.lru alloc_id entry;
      Lwt.return entry

  let free_space entry =
    match entry.cached_node with
    |`Root
    |`Child -> entry.childlinks.childlinks_offset - entry.keydata.next_keydata_offset - redzone_size

  type root = {
    open_fs: open_fs;
    root_key: LRUKey.t;
  }

  let _write_node open_fs alloc_id =
    let cache = open_fs.node_cache in
    match lru_get cache.lru alloc_id with
    |None -> failwith "missing lru entry in _write_node"
    |Some entry ->
    let gen = next_generation open_fs.node_cache in
    set_anynode_hdr_generation entry.raw_node gen;
    Crc32c.cstruct_reset entry.raw_node;
    let logical = next_logical_alloc_valid cache in
    Logs.info (fun m -> m "_write_node logical:%Ld gen:%Ld" logical gen);
    begin match lookup_parent_link cache.lru entry with
    |Some (parent_key, parent_entry, cl) ->
      assert (parent_key <> alloc_id);
      Cstruct.LE.set_uint64 parent_entry.raw_node (cl.offset + P.key_size) logical;
    |None -> () end;
    begin match entry.prev_logical with
    |Some plog ->
        begin
          cache.dirty_count <- int64_pred_nowrap cache.dirty_count;
          bitv_set64 cache.space_map plog false;
        end
    |None ->
        begin
          cache.free_count <- int64_pred_nowrap cache.free_count;
          cache.new_count <- int64_pred_nowrap cache.new_count;
        end;
      end;
    bitv_set64 cache.space_map logical true;
    entry.prev_logical <- Some logical;
    B.write open_fs.filesystem.disk
        Int64.(div (mul logical @@ of_int P.block_size) @@ of_int open_fs.filesystem.other_sector_size) entry.io_data >>= function
      |Result.Ok () -> Lwt.return ()
      |Result.Error _ -> Lwt.fail WriteError

  let _log_statistics cache =
    let stats = cache.statistics in
    Logs.info (fun m -> m "Ops: %d inserts %d lookups" stats.inserts stats.lookups);
    let logical_size = bitv_len64 cache.space_map in
    (* Don't count the superblock as a node *)
    let nstored = int64_pred_nowrap @@ Int64.sub logical_size cache.free_count in
    let ndirty = cache.dirty_count in
    let nnew = cache.new_count in
    Logs.info (fun m -> m "Nodes: %Ld on-disk (%Ld dirty), %Ld new" nstored ndirty nnew);
    Logs.info (fun m -> m "LRU: %d" (LRU.items cache.lru));
    ()

  let log_statistics root =
    let cache = root.open_fs.node_cache in
    _log_statistics cache

  let flush root =
    let open_fs = root.open_fs in
    Logs.info (fun m -> m "flushing %d dirty roots" (match open_fs.node_cache.flush_root with None -> 0 |Some _ -> 1));
    _log_statistics open_fs.node_cache;
    let rec flush_rec parent_key _key alloc_id (completion_list : unit Lwt.t list) = begin
      match lru_get open_fs.node_cache.lru alloc_id with
      |None -> failwith "missing alloc_id"
      |Some entry ->
          Logs.info (fun m -> m "collecting %Ld parent %Ld" alloc_id parent_key);
        match entry.flush_info with
        (* Can happen with a diamond pattern *)
        |None -> failwith "Flushed but missing flush_info"
        |Some di ->
      let completion_list = KeyedMap.fold (flush_rec alloc_id) di.flush_children completion_list in
      entry.flush_info <- None;
      (_write_node open_fs alloc_id) :: completion_list
    end in
    let r = Lwt.join (match open_fs.node_cache.flush_root with
        |None -> []
        |Some alloc_id ->
            flush_rec 0L zero_key alloc_id []
      ) in
    open_fs.node_cache.flush_root <- None;
    r >> Lwt.return @@ Int64.pred open_fs.node_cache.next_generation

  let _new_node open_fs tycode parent_key highest_key =
    let cache = open_fs.node_cache in
    let alloc_id = next_alloc_id cache in
    Logs.info (fun m -> m "_new_node type:%d alloc_id:%Ld" tycode alloc_id);
    let cstr = _get_block_io () in
    assert (Cstruct.len cstr = P.block_size);
    set_anynode_hdr_nodetype cstr tycode;
    let io_data = make_fanned_io_list open_fs.filesystem.sector_size cstr in
    let cached_node = match tycode with
    |1 -> `Root
    |2 -> `Child
    |ty -> raise @@ BadNodeType ty
    in
    let keydata = {keydata_offsets=[]; next_keydata_offset=sizeof_rootnode_hdr;} in
    let entry = {parent_key; cached_node; raw_node=cstr; io_data; keydata; flush_info=None; children=Lazy.from_val KeyedMap.empty; logindex=Lazy.from_val KeyedMap.empty; highest_key; prev_logical=None; childlinks={childlinks_offset=block_end;}} in
    lru_xset cache.lru alloc_id entry;
    alloc_id, entry

  let _new_root open_fs =
    _new_node open_fs 1 None top_key

  let _reset_contents entry =
    let hdrsize = header_size entry.cached_node in
    entry.keydata.next_keydata_offset <- hdrsize;
    entry.keydata.keydata_offsets <- [];
    entry.childlinks.childlinks_offset <- block_end;
    entry.logindex <- Lazy.from_val (KeyedMap.empty);
    entry.children <- Lazy.from_val (KeyedMap.empty);
    Cstruct.blit zero_data 0 entry.raw_node hdrsize (block_end - hdrsize)

  let _add_child parent child alloc_id cache parent_key =
    Logs.info (fun m -> m "_add_child");
    let child_key = alloc_id in
    let off = parent.childlinks.childlinks_offset - childlink_size in
    let children = Lazy.force parent.children in (* Force *before* blitting *)
    child.parent_key <- Some parent_key;
    Cstruct.blit (Cstruct.of_string child.highest_key) 0 parent.raw_node off P.key_size;
    parent.childlinks.childlinks_offset <- off;
    parent.children <- Lazy.from_val @@ KeyedMap.add (Cstruct.to_string @@ Cstruct.sub parent.raw_node off P.key_size) {offset=off; alloc_id=Some alloc_id} children;
    ignore @@ _mark_dirty cache parent_key;
    ignore @@ _mark_dirty cache child_key

  let _has_children entry =
    entry.childlinks.childlinks_offset <> block_end

  let _has_logdata entry =
    entry.keydata.next_keydata_offset <> header_size entry.cached_node

  let _logical_of_cl cstr cl =
    Cstruct.LE.get_uint64 cstr (cl.offset + P.key_size)

  let _ensure_childlink open_fs entry_key entry cl_key cl =
    (*Logs.info (fun m -> m "_ensure_childlink");*)
    let cstr = entry.raw_node in
    let cache = open_fs.node_cache in
    match cl.alloc_id with
    |None ->
        let logical = _logical_of_cl cstr cl in
        let%lwt child_entry = _load_child_node_at open_fs logical cl_key entry_key in
        let alloc_id = next_alloc_id cache in
        cl.alloc_id <- Some alloc_id;
        lru_xset cache.lru alloc_id child_entry;
        Lwt.return (alloc_id, child_entry)
    |Some alloc_id ->
      match lru_get cache.lru alloc_id with
      |None -> Lwt.fail @@ Failure (Printf.sprintf "Missing LRU entry for loaded child %s" (sexp_of_childlink_entry cl |> Sexplib.Sexp.to_string))
      |Some child_entry ->
        Lwt.return (alloc_id, child_entry)

  let _ins_req_space = function
    |InsValue value ->
        let len = Cstruct.len value in
        let len1 = P.key_size + sizeof_datalen + len in
        len1
    |InsChild (_loc, _alloc_id) ->
        P.key_size + sizeof_logical

  let _fast_insert fs alloc_id key insertable _depth =
    (*Logs.info (fun m -> m "_fast_insert %d" _depth);*)
    match lru_get fs.node_cache.lru alloc_id with
    |None -> failwith @@ Printf.sprintf "Missing LRU entry for %Ld (_fast_insert)" alloc_id
    |Some entry ->
    assert (String.compare key entry.highest_key <= 0);
    let free = free_space entry in begin
      assert (free >= _ins_req_space insertable);
      begin (* Simple insertion *)
        match insertable with
        |InsValue value ->
          let len = Cstruct.len value in
          let len1 = P.key_size + sizeof_datalen + len in
          let cstr = entry.raw_node in
          let kd = entry.keydata in
          let off = kd.next_keydata_offset in begin
            kd.next_keydata_offset <- kd.next_keydata_offset + len1;
            Cstruct.blit (Cstruct.of_string key) 0 cstr off P.key_size;
            Cstruct.LE.set_uint16 cstr (off + P.key_size) len;
            Cstruct.blit value 0 cstr (off + P.key_size + sizeof_datalen) len;
            kd.keydata_offsets <- off::kd.keydata_offsets;
            if Lazy.is_val entry.logindex then
              entry.logindex <- Lazy.from_val @@ KeyedMap.add (Cstruct.to_string @@ Cstruct.sub cstr off P.key_size) off (Lazy.force entry.logindex)
          end;
          ignore @@ _mark_dirty fs.node_cache alloc_id;
        |InsChild (loc, child_alloc_id) ->
          let cstr = entry.raw_node in
          let cls = entry.childlinks in
          let offset = cls.childlinks_offset - childlink_size in
          let children = Lazy.force entry.children in
          cls.childlinks_offset <- offset;
          Cstruct.blit (Cstruct.of_string key) 0 cstr offset P.key_size;
          Cstruct.LE.set_uint64 cstr (offset + P.key_size) loc;
          let cl = { offset; alloc_id=child_alloc_id; } in
          entry.children <- Lazy.from_val @@ KeyedMap.add (Cstruct.to_string @@ Cstruct.sub cstr offset P.key_size) cl children;
          ignore @@ _mark_dirty fs.node_cache alloc_id;
      end
    end

  let _split_point entry =
    if _has_children entry then
      let children = Lazy.force entry.children in
      let n = KeyedMap.cardinal children in
      let binds = KeyedMap.bindings children in
      let median = fst @@ List.nth binds @@ n/2 in
      median
    else
      let logindex = Lazy.force entry.logindex in
      let n = KeyedMap.cardinal logindex in
      let binds = KeyedMap.bindings logindex in
      let median = fst @@ List.nth binds @@ n/2 in
      median

  let rec _check_live_integrity fs alloc_id depth =
    let fail = ref false in
    match lru_peek fs.node_cache.lru alloc_id with
    |None -> failwith "Missing LRU entry"
    |Some entry -> begin
        if _has_children entry && not (String.equal entry.highest_key @@ fst @@ KeyedMap.max_binding @@ Lazy.force entry.children) then begin
          string_dump @@ entry.highest_key;
          string_dump @@ fst @@ KeyedMap.max_binding @@ Lazy.force entry.children;
          Logs.info (fun m -> m "_check_live_integrity %d invariant broken: highest_key" depth);
          fail := true;
        end;
        match entry.parent_key with
        |None -> ()
        |Some parent_key -> begin
            match lru_peek fs.node_cache.lru parent_key with
            |None -> failwith "Missing parent"
            |Some parent_entry ->
              let children = Lazy.force parent_entry.children in
              match KeyedMap.find_opt entry.highest_key children with
              |None ->
                Logs.info (fun m -> m "_check_live_integrity %d invariant broken: lookup_parent_link" depth);
                fail := true;
              |Some cl ->
                assert (cl.alloc_id = Some alloc_id);
          end;
      end;
      if entry.flush_info <> None then begin
        match entry.parent_key with
        |None -> ()
        |Some parent_key ->
            match lru_peek fs.node_cache.lru parent_key with
            |None -> failwith "Missing parent"
            |Some parent_entry ->
                match parent_entry.flush_info with
                |None -> failwith "Missing parent_entry.flush_info"
                |Some di -> let n = KeyedMap.fold (fun _k el acc -> if el = alloc_id then acc + 1 else acc) di.flush_children 0 in
                if n = 0 then begin
                  Logs.info (fun m -> m "Dirty but not registered in parent_entry.flush_info %d" depth);
                  fail := true;
                end else if n > 1 then begin
                  Logs.info (fun m -> m "Dirty, registered %d times in parent_entry.flush_info %d" n depth);
                  fail := true;
                end
      end else begin
        match entry.parent_key with
        |None -> ()
        |Some parent_key ->
            match lru_peek fs.node_cache.lru parent_key with
            |None -> failwith "Missing parent"
            |Some parent_entry ->
                match parent_entry.flush_info with
                |None -> ()
                |Some di -> if KeyedMap.exists (fun _k el -> el = alloc_id) di.flush_children then begin
                  Logs.info (fun m -> m "Not dirty but registered in parent_entry.flush_info %d" depth);
                  fail := true;
                end
      end;
      KeyedMap.iter (fun _k v -> match v.alloc_id with
          |None -> ()
          |Some alloc_id -> _check_live_integrity fs
            alloc_id @@ depth + 1
        ) @@ Lazy.force entry.children;
      if !fail then assert(false)

  let _fixup_parent_links cache alloc_id entry =
    KeyedMap.iter (fun _k v -> match v.alloc_id with
          None -> ()
        |Some child_alloc_id ->
          match lru_peek cache.lru child_alloc_id with
          |None -> failwith "Missing LRU entry"
          |Some centry -> centry.parent_key <- Some alloc_id
      ) @@ Lazy.force entry.children

  (* lwt because it might load from disk *)
  let rec _reserve_insert fs alloc_id size split_path depth =
    (*Logs.info (fun m -> m "_reserve_insert %d" depth);*)
    _check_live_integrity fs alloc_id depth;
    match lru_get fs.node_cache.lru alloc_id with
    |None -> failwith @@ Printf.sprintf "Missing LRU entry for %Ld (insert)" alloc_id
    |Some entry ->
    let free = free_space entry in
      if free >= size then
        Lwt.return ()
      else if not split_path && _has_children entry && _has_logdata entry then begin
        (* log spilling *)
        Logs.info (fun m -> m "log spilling %d" depth);
        let children = Lazy.force entry.children in
        let find_victim () =
          let spill_score = ref 0 in
          let best_spill_score = ref 0 in
          (* an iterator on entry.children keys would be helpful here *)
          let scored_key = ref @@ fst @@ KeyedMap.min_binding children in
          let best_spill_key = ref !scored_key in
          KeyedMap.iter (fun k off -> begin
            if String.compare k !scored_key > 0 then begin
              if !spill_score > !best_spill_score then begin
                best_spill_score := !spill_score;
                best_spill_key := !scored_key;
              end;
              spill_score := 0;
              match KeyedMap.find_first_opt (fun k1 -> String.compare k k1 <= 0) children with
              |None -> string_dump k; string_dump @@ fst @@ KeyedMap.max_binding children; string_dump entry.highest_key; failwith "children invariant broken"
              |Some (sk, _cl) ->
                scored_key := sk;
            end;
            let len = Cstruct.LE.get_uint16 entry.raw_node (off + P.key_size) in
            let len1 = P.key_size + sizeof_datalen + len in
            spill_score := !spill_score + len1;
          end) @@ Lazy.force entry.logindex;
          if !spill_score > !best_spill_score then begin
            best_spill_score := !spill_score;
            best_spill_key := !scored_key;
          end;
          !best_spill_score, !best_spill_key
        in
        let best_spill_score, best_spill_key = find_victim () in
        let cl = KeyedMap.find best_spill_key children in
        let%lwt child_alloc_id, _ce = _ensure_childlink fs alloc_id entry best_spill_key cl in begin
        let clo = entry.childlinks.childlinks_offset in
        let nko = entry.keydata.next_keydata_offset in
        Logs.info (fun m -> m "Before _reserve_insert nko %d" entry.keydata.next_keydata_offset);
        _reserve_insert fs child_alloc_id best_spill_score false @@ depth + 1 >> begin
        Logs.info (fun m -> m "After _reserve_insert nko %d" entry.keydata.next_keydata_offset);
        if clo = entry.childlinks.childlinks_offset && nko = entry.keydata.next_keydata_offset then begin
        (* _reserve_insert didn't split the child or the root *)
        let before_bsk = KeyedMap.find_last_opt (fun k1 -> String.compare k1 best_spill_key < 0) children in
        (* loop across log data, shifting/blitting towards the start if preserved,
         * sending towards victim child if not *)
        let kdo_out = ref @@ header_size entry.cached_node in
        let kdos = List.fold_right (fun kdo kdos ->
          let key1 = Cstruct.to_string @@ Cstruct.sub entry.raw_node kdo P.key_size in
          let len = Cstruct.LE.get_uint16 entry.raw_node (kdo + P.key_size) in
          if String.compare key1 best_spill_key <= 0 && match before_bsk with None -> true |Some (bbsk, _cl1) -> String.compare bbsk key1 < 0 then begin
            let value1 = Cstruct.sub entry.raw_node (kdo + P.key_size + sizeof_datalen) len in
            _fast_insert fs child_alloc_id key1 (InsValue value1) @@ depth + 1;
            kdos
          end else begin
            let len1 = len + P.key_size + sizeof_datalen in
            Cstruct.blit entry.raw_node kdo entry.raw_node !kdo_out len1;
            let kdos = !kdo_out::kdos in
            kdo_out := !kdo_out + len1;
            kdos
          end
        ) entry.keydata.keydata_offsets [] in begin
        entry.keydata.keydata_offsets <- kdos;
        if not (!kdo_out < entry.keydata.next_keydata_offset) then begin
          (match before_bsk with None -> Logs.info (fun m -> m "No before_bsk") |Some (bbsk, _) -> string_dump bbsk);
          string_dump best_spill_key;
          failwith @@ Printf.sprintf "Key data didn't shrink %d %d %d" !kdo_out entry.keydata.next_keydata_offset @@ header_size entry.cached_node
        end;
        (* zero newly free space *)
        Cstruct.blit zero_data 0 entry.raw_node !kdo_out (entry.keydata.next_keydata_offset - !kdo_out);
        entry.keydata.next_keydata_offset <- !kdo_out;
        (* Invalidate logcache since keydata_offsets changed *)
        entry.logindex <- lazy (_compute_keydata entry);
        end
        end;
        _reserve_insert fs alloc_id size split_path depth
        end
        end
      end
      else match entry.parent_key with
      |None -> begin (* Node splitting (root) *)
        assert (depth = 0);
        Logs.info (fun m -> m "node splitting %d %Ld" depth alloc_id);
        let logindex = Lazy.force entry.logindex in
        let children = Lazy.force entry.children in
        (* Mark parent dirty before marking children new, so that
         * OutOfSpace / NeedsFlush are discriminated *)
        let di = _mark_dirty fs.node_cache alloc_id in
        let median = _split_point entry in
        let alloc1, entry1 = _new_node fs 2 (Some alloc_id) median in
        let alloc2, entry2 = _new_node fs 2 (Some alloc_id) entry.highest_key in
        let logi1, logi2 = KeyedMap.partition (fun k _v -> String.compare k median <= 0) logindex in
        let cl1, cl2 = KeyedMap.partition (fun k _v -> String.compare k median <= 0) children in
        let fc1, fc2 = KeyedMap.partition (fun k _v -> String.compare k median <= 0) di.flush_children in
        let blit_kd_child off centry =
          let cstr0 = entry.raw_node in
          let cstr1 = centry.raw_node in
          let ckd = centry.keydata in
          let off1 = ckd.next_keydata_offset in
          let len = Cstruct.LE.get_uint16 cstr0 (off + P.key_size) in
          let len1 = P.key_size + sizeof_datalen + len in
          Cstruct.blit cstr0 off cstr1 off1 len1;
          ckd.keydata_offsets <- off1::ckd.keydata_offsets;
          ckd.next_keydata_offset <- ckd.next_keydata_offset + len1;
          if Lazy.is_val centry.logindex then
            centry.logindex <- Lazy.from_val @@ KeyedMap.add (Cstruct.to_string @@ Cstruct.sub cstr1 off1 P.key_size) off1 (Lazy.force centry.logindex);
        in let blit_cd_child cle centry =
          let cstr0 = entry.raw_node in
          let cstr1 = centry.raw_node in
          let offset = centry.childlinks.childlinks_offset - childlink_size in
          centry.childlinks.childlinks_offset <- offset;
          Cstruct.blit cstr0 cle.offset cstr1 offset (childlink_size);
          centry.children <- Lazy.from_val @@ KeyedMap.add (Cstruct.to_string @@ Cstruct.sub cstr1 offset P.key_size) {offset; alloc_id=cle.alloc_id} (Lazy.force centry.children);
        in
        KeyedMap.iter (fun _k off -> blit_kd_child off entry1) logi1;
        KeyedMap.iter (fun _k off -> blit_kd_child off entry2) logi2;
        KeyedMap.iter (fun _k ce -> blit_cd_child ce entry1) cl1;
        KeyedMap.iter (fun _k ce -> blit_cd_child ce entry2) cl2;
        let fc = KeyedMap.empty in
        let fc = KeyedMap.add median alloc1 fc in
        let fc = KeyedMap.add entry.highest_key alloc2 fc in
        _reset_contents entry;
        _add_child entry entry1 alloc1 fs.node_cache alloc_id;
        _add_child entry entry2 alloc2 fs.node_cache alloc_id;
        entry1.flush_info <- Some { flush_children=fc1 };
        entry2.flush_info <- Some { flush_children=fc2 };
        entry.flush_info <- Some { flush_children=fc };
        _fixup_parent_links fs.node_cache alloc1 entry1;
        _fixup_parent_links fs.node_cache alloc2 entry2;
        Lwt.return ()
      end
      |Some parent_key -> begin (* Node splitting (non root) *)
        assert (depth > 0);
        Logs.info (fun m -> m "node splitting %d %Ld" depth alloc_id);
        (* Set split_path to prevent spill/split recursion; will split towards the root *)
        _reserve_insert fs parent_key childlink_size true @@ depth - 1 >>
        let _logindex = Lazy.force entry.logindex in
        let _children = Lazy.force entry.children in
        (* Mark parent dirty before marking children new, so that
         * OutOfSpace / NeedsFlush are discriminated *)
        let di = _mark_dirty fs.node_cache alloc_id in
        let median = _split_point entry in
        let alloc1, entry1 = _new_node fs 2 (Some alloc_id) median in
        let alloc_id1 = alloc1 in
        let kdo_out = ref @@ header_size entry.cached_node in
        let kdos = List.fold_right (fun kdo kdos ->
          let key1 = Cstruct.to_string @@ Cstruct.sub entry.raw_node kdo P.key_size in
          let len = Cstruct.LE.get_uint16 entry.raw_node (kdo + P.key_size) in
          if String.compare key1 median <= 0 then begin
            let value1 = Cstruct.sub entry.raw_node (kdo + P.key_size + sizeof_datalen) len in
            _fast_insert fs alloc_id1 key1 (InsValue value1) depth;
            kdos
          end else begin
            let len1 = len + P.key_size + sizeof_datalen in
            Cstruct.blit entry.raw_node kdo entry.raw_node !kdo_out len1;
            let kdos = !kdo_out::kdos in
            kdo_out := !kdo_out + len1;
            kdos
          end
        ) entry.keydata.keydata_offsets [] in begin
        entry.keydata.keydata_offsets <- kdos;
        if not (!kdo_out < entry.keydata.next_keydata_offset) then begin
          failwith @@ Printf.sprintf "Key data didn't shrink %d %d" !kdo_out entry.keydata.next_keydata_offset
        end;
        (* zero newly free space *)
        Cstruct.blit zero_data 0 entry.raw_node !kdo_out (entry.keydata.next_keydata_offset - !kdo_out);
        entry.keydata.next_keydata_offset <- !kdo_out;
        (* Invalidate logcache since keydata_offsets changed *)
        entry.logindex <- lazy (_compute_keydata entry);
        let clo_out = ref block_end in
        let clo_out1 = ref block_end in
        let clo = ref @@ block_end - childlink_size in
        let children = ref @@ Lazy.force entry.children in
        let children1 = ref @@ KeyedMap.empty in
        let fc1 = ref @@ KeyedMap.empty in
        while !clo >= entry.childlinks.childlinks_offset do
        (* Move children data *)
          let key1 = Cstruct.to_string @@ Cstruct.sub entry.raw_node !clo P.key_size in
          if String.compare key1 median <= 0 then begin
            clo_out1 := !clo_out1 - childlink_size;
            Cstruct.blit entry.raw_node !clo entry1.raw_node !clo_out1 childlink_size;
            let cl = KeyedMap.find key1 !children in
            children := KeyedMap.remove key1 !children;
            children1 := KeyedMap.add key1 {cl with offset = !clo_out1} !children1;
            if KeyedMap.mem key1 di.flush_children then begin
              let child_alloc_id = KeyedMap.find key1 di.flush_children in
              di.flush_children <- KeyedMap.remove key1 di.flush_children;
              fc1 := KeyedMap.add key1 child_alloc_id !fc1;
            end
          end else begin
            clo_out := !clo_out - childlink_size;
            Cstruct.blit entry.raw_node !clo entry.raw_node !clo_out childlink_size;
            let key1 = Cstruct.to_string @@ Cstruct.sub entry.raw_node !clo_out P.key_size in
            let cl = KeyedMap.find key1 !children in
            children := KeyedMap.add key1 {cl with offset = !clo_out} !children
          end
        done;
        entry.childlinks.childlinks_offset <- !clo_out;
        entry1.childlinks.childlinks_offset <- !clo_out1;
        entry.children <- Lazy.from_val !children;
        entry1.children <- Lazy.from_val !children1;
        _fixup_parent_links fs.node_cache alloc1 entry1;
        (* Hook new node into parent *)
        match lru_peek fs.node_cache.lru parent_key with
        |None -> failwith @@ Printf.sprintf "Missing LRU entry for %Ld (parent)" alloc_id
        |Some parent -> begin
          _add_child parent entry1 alloc1 fs.node_cache parent_key;
          entry1.flush_info <- Some { flush_children = !fc1 };
          match parent.flush_info with
          |None -> failwith "Missing flush_info for parent"
          |Some di ->
              di.flush_children <- KeyedMap.add median alloc1 di.flush_children;
          end;
        _reserve_insert fs alloc_id size split_path depth;
      end
    end

  let insert root key value =
    Logs.info (fun m -> m "insert");
    let _len = Cstruct.len value in
    let stats = root.open_fs.node_cache.statistics in
    stats.inserts <- succ stats.inserts;
    _check_live_integrity root.open_fs root.root_key 0;
    _reserve_insert root.open_fs root.root_key (_ins_req_space @@ InsValue value) false 0 >>
    begin
      _check_live_integrity root.open_fs root.root_key 0;
      _fast_insert root.open_fs root.root_key key (InsValue value) 0;
      _check_live_integrity root.open_fs root.root_key 0;
      Lwt.return ()
    end

  let rec _lookup open_fs alloc_id key =
    match lru_get open_fs.node_cache.lru alloc_id with
    |None -> failwith @@ Printf.sprintf "Missing LRU entry for %Ld (lookup)" alloc_id
    |Some entry ->
    let cstr = entry.raw_node in
      match
        KeyedMap.find key @@ Lazy.force entry.logindex
      with
        |logoffset ->
            let len = Cstruct.LE.get_uint16 cstr (logoffset + P.key_size) in
            Lwt.return @@ Cstruct.sub cstr (logoffset + P.key_size + 2) len
        |exception Not_found ->
            Logs.info (fun m -> m "_lookup");
            let key1, cl = KeyedMap.find_first (
              fun k -> String.compare k key >= 0) @@ Lazy.force entry.children in
            let%lwt child_alloc_id, _ce = _ensure_childlink open_fs alloc_id entry key1 cl in
            _lookup open_fs child_alloc_id key

  let lookup root key =
    let stats = root.open_fs.node_cache.statistics in
    stats.lookups <- succ stats.lookups;
    _lookup root.open_fs root.root_key key

  let rec _search_range open_fs alloc_id start_cond end_cond seen callback =
    match lru_get open_fs.node_cache.lru alloc_id with
    |None -> failwith @@ Printf.sprintf "Missing LRU entry for %Ld (search_range)" alloc_id
    |Some entry ->
      (* TODO get iter_from_first into the stdlib *)
      let seen1 = ref seen in
      let lwt_queue = ref [] in
      csm_iter_range start_cond end_cond (fun k _v -> callback k; seen1 := KeyedSet.add k !seen1)
      @@ Lazy.force entry.logindex;
      csm_iter_range_plus start_cond end_cond (fun key1 cl ->
        lwt_queue := (key1, cl)::!lwt_queue)
      @@ Lazy.force entry.children;
      Lwt_list.iter_s (fun (key1, cl) ->
          let%lwt child_alloc_id, _ce =
            _ensure_childlink open_fs alloc_id entry key1 cl in
          _search_range open_fs child_alloc_id start_cond end_cond !seen1 callback) !lwt_queue

  (* The range where start_cond and not end_cond
     Results are in no particular order. *)
  let search_range root start_cond end_cond callback =
    let seen = KeyedSet.empty in
    let stats = root.open_fs.node_cache.statistics in
    stats.range_searches <- succ stats.range_searches;
    _search_range root.open_fs root.root_key start_cond end_cond seen callback

  let rec _scan_all_nodes open_fs logical depth parent_gen =
    Logs.info (fun m -> m "_scan_all_nodes %Ld %d" logical depth);
    (* TODO add more fsck style checks *)
    let cache = open_fs.node_cache in
    let sm = bitv_get64 cache.space_map logical in
    if sm then failwith "logical address referenced twice";
    bitv_set64 cache.space_map logical true;
    cache.free_count <- int64_pred_nowrap cache.free_count;
    let%lwt cstr, _io_data = _load_data_at open_fs.filesystem logical in
    let hdrsize = match get_anynode_hdr_nodetype cstr with
      |1 (* root *) when depth = 0 -> sizeof_rootnode_hdr
      |2 (* inner *) when depth > 0 -> sizeof_childnode_hdr
      |ty -> raise @@ BadNodeType ty
    in
    let gen = get_anynode_hdr_generation cstr in
    (* prevents cycles *)
    if gen >= parent_gen then failwith "generation is not lower than for parent";
    let rec scan_key off =
      if off < hdrsize + redzone_size - sizeof_logical then failwith "child link data bleeding into start of node";
      let log1 = Cstruct.LE.get_uint64 cstr (off + P.key_size) in
      begin if log1 <> 0L then
        _scan_all_nodes open_fs log1 (depth + 1) gen >> scan_key (off - childlink_size)
      else if redzone_size > sizeof_logical && not @@ is_zero_key @@ Cstruct.to_string @@ Cstruct.sub cstr (off + sizeof_logical - redzone_size) redzone_size then
        Lwt.fail @@ Failure "partial redzone"
      else Lwt.return () end in
      scan_key (block_end - childlink_size)

  let _sb_io block_io =
    Cstruct.sub block_io 0 sizeof_superblock

  let _read_superblock fs =
    let block_io = _get_superblock_io () in
    let block_io_fanned = make_fanned_io_list fs.sector_size block_io in
    B.read fs.disk 0L block_io_fanned >>= Lwt.wrap1 begin function
      |Result.Error _ -> raise ReadError
      |Result.Ok () ->
          let sb = _sb_io block_io in
      if Cstruct.to_string @@ get_superblock_magic sb <> superblock_magic
      then raise BadMagic
      else if get_superblock_version sb <> superblock_version
      then raise BadVersion
      else if get_superblock_incompat_flags sb <> 0l
      then raise BadFlags
      else if not @@ Crc32c.cstruct_valid sb
      then raise @@ BadCRC 0L
      else if get_superblock_block_size sb <> Int32.of_int P.block_size
      then raise BadParams
      else if get_superblock_key_size sb <> P.key_size
      then raise BadParams
      else get_superblock_first_block_written sb, get_superblock_logical_size sb
    end

  (* Requires the caller to discard the entire device first.
     Don't add call sites beyond prepare_io, the io pages must be zeroed *)
  let _format open_fs logical_size first_block_written =
    let block_io = _get_superblock_io () in
    let block_io_fanned = make_fanned_io_list open_fs.filesystem.sector_size block_io in
    let alloc_id, _root = _new_root open_fs in
    open_fs.node_cache.new_count <- 1L;
    _write_node open_fs alloc_id >> begin
    _log_statistics open_fs.node_cache;
    let sb = _sb_io block_io in
    set_superblock_magic superblock_magic 0 sb;
    set_superblock_version sb superblock_version;
    set_superblock_block_size sb (Int32.of_int P.block_size);
    set_superblock_key_size sb P.key_size;
    set_superblock_first_block_written sb first_block_written;
    set_superblock_logical_size sb logical_size;
    Crc32c.cstruct_reset sb;
    B.write open_fs.filesystem.disk 0L block_io_fanned >>= function
      |Result.Ok () -> Lwt.return ()
      |Result.Error _ -> Lwt.fail WriteError
    end

  let _mid_range start end_ lsize = (* might overflow, limit lsize *)
    (* if start = end_, we pick the farthest logical address *)
    if Int64.(succ start) = end_ || (
      Int64.(succ start) = lsize && end_ = 1L) then None else
    let end_ = if Int64.compare start end_ < 0 then end_ else Int64.(add end_ lsize) in
    let mid = Int64.(shift_right_logical (add start end_) 1) in
    let mid = Int64.(rem mid lsize) in
    let mid = if mid = 0L then 1L else mid in
    Some mid

  let _scan_for_root fs start0 lsize =
    Logs.info (fun m -> m "_scan_for_root");
    let cstr = _get_block_io () in
    let io_data = make_fanned_io_list fs.sector_size cstr in

    let read logical =
      B.read fs.disk Int64.(div (mul logical @@ of_int P.block_size) @@ of_int fs.other_sector_size) io_data >>= function
      |Result.Error _ -> Lwt.fail ReadError
      |Result.Ok () -> Lwt.return () in

    let next_logical logical =
      let log1 = Int64.succ logical in
      if log1 = lsize then 1L else log1
    in

    let is_valid_root () =
      get_anynode_hdr_nodetype cstr = 1
      && Crc32c.cstruct_valid cstr
    in

    let rec _scan_range start =
      (* Placeholder.
         TODO _scan_range start end
         TODO use _is_zero_data, type checks, crc checks, and loop *)
      read start >>
      if is_valid_root () then
        Lwt.return (start, get_anynode_hdr_generation cstr)
      else
        _scan_range @@ next_logical start
    in

    let rec sfr_rec start0 end0 gen0 =
      (* end/start swapped on purpose *)
      match _mid_range end0 start0 lsize with
      | None -> Lwt.return end0
      | Some start1 ->
      let%lwt end1, gen1 = _scan_range start1 in
      if gen0 < gen1
      then sfr_rec start0 end1 gen1
      else sfr_rec start1 end0 gen0 in

    let%lwt end0, gen0 = _scan_range start0
    in sfr_rec start0 end0 gen0

  let prepare_io mode disk cache_size =
    B.get_info disk >>= fun info ->
      Logs.info (fun m -> m "prepare_io sector_size %d" info.sector_size);
      let sector_size = if false then info.sector_size else 512 in
      let block_size = P.block_size in
      let io_size = if block_size >= Io_page.page_size then Io_page.page_size else block_size in
      assert (block_size >= io_size);
      assert (io_size >= sector_size);
      assert (block_size mod io_size = 0);
      assert (io_size mod sector_size = 0);
      let fs = {
        disk;
        sector_size;
        other_sector_size = info.sector_size;
      } in
      match mode with
        |OpenExistingDevice ->
            let%lwt fbw, logical_size = _read_superblock fs in
            let%lwt lroot = _scan_for_root fs fbw logical_size in
            let%lwt cstr, _io_data = _load_data_at fs lroot in
            let typ = get_anynode_hdr_nodetype cstr in
            if typ <> 1 then raise @@ BadNodeType typ;
            let root_generation = get_rootnode_hdr_generation cstr in
            let space_map = bitv_create64 logical_size false in
            Bitv.set space_map 0 true;
            let free_count = Int64.pred logical_size in
            let node_cache = {
              lru=lru_create cache_size;
              flush_root=None;
              next_alloc_id=1L;
              next_generation=Int64.succ root_generation;
              logical_size;
              space_map;
              free_count;
              new_count=0L;
              dirty_count=0L;
              next_logical_alloc=lroot; (* in use, but that's okay *)
              statistics=default_statistics;
            } in
            let open_fs = { filesystem=fs; node_cache; } in
            (* TODO add more integrity checking *)
            _scan_all_nodes open_fs lroot 0 Int64.max_int >>
            let%lwt root_key, _entry = _load_root_node_at open_fs lroot in
            let root = {open_fs; root_key;} in
            log_statistics root;
            Lwt.return (root, root_generation)
        |FormatEmptyDevice logical_size ->
            assert (logical_size >= 2L);
            let space_map = bitv_create64 logical_size false in
            Bitv.set space_map 0 true;
            let free_count = Int64.pred logical_size in
            let first_block_written = Nocrypto.Rng.Int64.gen_r 1L logical_size in
            let node_cache = {
              lru=lru_create cache_size;
              flush_root=None;
              next_alloc_id=1L;
              next_generation=1L;
              logical_size;
              space_map;
              free_count;
              new_count=0L;
              dirty_count=0L;
              next_logical_alloc=first_block_written;
              statistics=default_statistics;
            } in
            let open_fs = { filesystem=fs; node_cache; } in
            _format open_fs logical_size first_block_written >>
            let root_key = 1L in
            Lwt.return ({open_fs; root_key;}, 1L)
end

