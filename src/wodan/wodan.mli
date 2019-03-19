(********************************************************************************)
(*  Copyright 2017-2019 Gabriel de Perthuis <g2p.code@gmail.com>                *)
(*                                                                              *)
(*  Permission to use, copy, modify, and/or distribute this software for any    *)
(*  purpose with or without fee is hereby granted, provided that the above      *)
(*  copyright notice and this permission notice appear in all copies.           *)
(*                                                                              *)
(*  THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES    *)
(*  WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF            *)
(*  MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR     *)
(*  ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES      *)
(*  WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN       *)
(*  ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR  *)
(*  IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.                 *)
(*                                                                              *)
(********************************************************************************)

val max_dirty : int

exception BadMagic

exception BadVersion

exception BadFlags

exception BadCRC of int64

exception BadParams

exception ReadError

exception WriteError

exception OutOfSpace

exception NeedsFlush

exception BadKey of string

exception ValueTooLarge of string

exception BadNodeType of int

module type EXTBLOCK = sig
  include Mirage_types_lwt.BLOCK

  val discard : t -> int64 -> int64 -> (unit, write_error) result io
end

module BlockCompat (B : Mirage_types_lwt.BLOCK) : EXTBLOCK with type t = B.t

type insertable =
  | InsValue of string
  | InsChild of (* loc, alloc_id *) int64 * int64 option

val sizeof_superblock : int

(** All parameters that can't be read from the superblock *)
type mount_options = {
  (* XXX Should this be a superblock flag? *)
  has_tombstone : bool;
      (** Whether the empty value should be considered a tombstone,
          meaning that `mem` will return no value when finding it *)
  fast_scan : bool;
      (** If enabled, instead of checking the entire filesystem when opening,
          leaf nodes won't be scanned.  They will be scanned on open instead. *)
  cache_size : int  (** How many blocks to keep in cache *)
}

(** All parameters that can be read from the superblock *)
module type SUPERBLOCK_PARAMS = sig
  val block_size : int
  (** Size of blocks, in bytes *)

  val key_size : int
  (** The exact size of all keys, in bytes *)
end

module StandardSuperblockParams : SUPERBLOCK_PARAMS

val standard_mount_options : mount_options

val read_superblock_params :
  (module Mirage_types_lwt.BLOCK with type t = 'a) ->
  'a ->
  (module SUPERBLOCK_PARAMS) Lwt.t

type deviceOpenMode =
  | OpenExistingDevice
  | FormatEmptyDevice of int64

module type S = sig
  (** An opaque type for fixed-size keys

      Conversion from/to strings is free *)
  type key

  (** An opaque type for bounded-size values

      Conversion from/to strings is free *)
  type value

  (** A backing device *)
  type disk

  (** A filesystem root *)
  type root

  (** Operations over keys *)
  module Key : sig
    type t = key

    val equal : t -> t -> bool

    val hash : t -> int

    val compare : t -> t -> int
  end

  (** The parameter module that was used to create this module *)
  module P : SUPERBLOCK_PARAMS

  val key_of_cstruct : Cstruct.t -> key

  val key_of_string : string -> key

  val key_of_string_padded : string -> key

  val cstruct_of_key : key -> Cstruct.t

  val string_of_key : key -> string

  val value_of_cstruct : Cstruct.t -> value

  val value_of_string : string -> value

  val value_equal : value -> value -> bool

  val cstruct_of_value : value -> Cstruct.t

  val string_of_value : value -> string

  val next_key : key -> key
  (** The next highest key

      Raises Invalid_argument if already at the highest possible key *)

  val is_tombstone : root -> value -> bool
  (** Whether a value is a tombstone within a root *)

  val insert : root -> key -> value -> unit Lwt.t
  (** Store data in the filesystem

      Any previously stored value will be silently overwritten *)

  val lookup : root -> key -> value option Lwt.t
  (** Read data from the filesystem *)

  val mem : root -> key -> bool Lwt.t
  (** Check whether a key has been set within the filesystem *)

  val flush : root -> int64 Lwt.t
  (** Send changes to disk *)

  val fstrim : root -> int64 Lwt.t
  (** Discard all blocks which the filesystem doesn't explicitly use *)

  val live_trim : root -> int64 Lwt.t
  (** Discard blocks that have been unused since mounting
   or since the last live_trim call *)

  val log_statistics : root -> unit
  (** Send statistics about operations to the log *)

  val search_range :
    root -> key -> key -> (key -> value -> unit) -> unit Lwt.t
  (** Call back a function for all elements in the range from start inclusive to end_ exclusive

      Results are in no particular order. *)

  val iter : root -> (key -> value -> unit) -> unit Lwt.t
  (** Call back a function for all elements in the filesystem *)

  val prepare_io :
    deviceOpenMode -> disk -> mount_options -> (root * int64) Lwt.t
  (** Open a filesystem *)
end

module Make (B : EXTBLOCK) (P : SUPERBLOCK_PARAMS) : S with type disk = B.t

type open_ret =
  | OPEN_RET : (module S with type root = 'a) * 'a * int64 -> open_ret

val open_for_reading :
  (module EXTBLOCK with type t = 'a) -> 'a -> mount_options -> open_ret Lwt.t
