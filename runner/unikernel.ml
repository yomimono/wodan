open Mirage_types_lwt
open Lwt.Infix

module Client (C: CONSOLE) (B: BLOCK) = struct
  module Stor = Storage.Make(B)(Storage.StandardParams)

  let start _con disk _crypto =
    let ios = ref 0 in
    let time0 = ref 0. in
    let%lwt info = B.get_info disk in
    let%lwt rootval, _gen0 = Stor.prepare_io (Storage.FormatEmptyDevice
      Int64.(div (mul info.size_sectors @@ of_int info.sector_size) @@ of_int Storage.StandardParams.block_size)) disk 1024 in
    (
    let root = ref rootval in
    let key = Stor.key_of_cstruct @@ Cstruct.of_string "abcdefghijklmnopqrst" in
    let cval = Stor.value_of_cstruct @@ Cstruct.of_string "sqnlnfdvulnqsvfjlllsvqoiuuoezr" in
    Stor.insert !root key cval >>
    Stor.flush !root >>= function gen1 ->
    let%lwt Some cval1 = Stor.lookup !root key in
    (*Cstruct.hexdump cval1;*)
    assert (Cstruct.equal (Stor.cstruct_of_value cval) (Stor.cstruct_of_value cval1));
    let%lwt rootval, gen2 = Stor.prepare_io Storage.OpenExistingDevice disk 1024 in
    root := rootval;
    let%lwt Some cval2 = Stor.lookup !root key in
    assert (Cstruct.equal (Stor.cstruct_of_value cval) (Stor.cstruct_of_value cval2));
    if gen1 <> gen2 then begin Logs.err (fun m -> m "Generation fail %Ld %Ld" gen1 gen2); assert false; end;
    time0 := Unix.gettimeofday ();
    while%lwt true do
      let key = Stor.key_of_cstruct @@ Nocrypto.Rng.generate 20 and
        cval = Stor.value_of_cstruct @@ Nocrypto.Rng.generate 40 in
      begin try%lwt
        ios := succ !ios;
        Stor.insert !root key cval
      with
      |Storage.NeedsFlush -> begin
        Logs.info (fun m -> m "Emergency flushing");
        Stor.flush !root >>= function _gen ->
        Stor.insert !root key cval
      end
      |Storage.OutOfSpace as e -> begin
        Logs.info (fun m -> m "Final flush");
        Stor.flush !root >|= ignore >>
        raise e
      end
      end
      >>
      if%lwt Lwt.return (Nocrypto.Rng.Int.gen 16384 = 0) then begin (* Infrequent re-opening *)
        Stor.flush !root >>= function gen3 ->
        let%lwt rootval, gen4 = Stor.prepare_io Storage.OpenExistingDevice disk 1024 in
        root := rootval;
        assert (gen3 = gen4);
        Lwt.return ()
      end
      else if%lwt Lwt.return (false && Nocrypto.Rng.Int.gen 8192 = 0) then begin (* Infrequent flushing *)
        Stor.log_statistics !root;
        Stor.flush !root >|= ignore
      end done
      ) >> begin
          let time1 = Unix.gettimeofday () in
          let iops = (float_of_int !ios) /. (time1 -. !time0) in
          Logs.info (fun m -> m "IOPS %f" iops);
          Lwt.return_unit
      end
      (*[%lwt.finally Lwt.return @@ Stor.log_statistics root]*)
end
