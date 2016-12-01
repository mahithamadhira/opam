(**************************************************************************)
(*                                                                        *)
(*    Copyright 2012-2015 OCamlPro                                        *)
(*    Copyright 2012 INRIA                                                *)
(*                                                                        *)
(*  All rights reserved. This file is distributed under the terms of the  *)
(*  GNU Lesser General Public License version 2.1, with the special       *)
(*  exception on linking described in the file LICENSE.                   *)
(*                                                                        *)
(**************************************************************************)

open OpamTypes
open OpamProcess.Job.Op

let log fmt = OpamConsole.log "REPOSITORY" fmt
let slog = OpamConsole.slog


let find_backend_by_kind = function
  | `http -> (module OpamHTTP.B: OpamRepositoryBackend.S)
  | `rsync -> (module OpamLocal.B: OpamRepositoryBackend.S)
  | `git -> (module OpamGit.B: OpamRepositoryBackend.S)
  | `hg -> (module OpamHg.B: OpamRepositoryBackend.S)
  | `darcs -> (module OpamDarcs.B: OpamRepositoryBackend.S)

let url_backend url = find_backend_by_kind url.OpamUrl.backend

let find_backend r = url_backend r.repo_url

(* initialize the current directory *)
let init root name =
  log "init local repo mirror at %s" (OpamRepositoryName.to_string name);
  (* let module B = (val find_backend repo: OpamRepositoryBackend.S) in *)
  let dir = OpamRepositoryPath.create root name in
  OpamFilename.cleandir dir;
  Done ()

let cache_url root_cache_url checksum =
  List.fold_left OpamUrl.Op.(/) root_cache_url
    (OpamHash.to_path checksum)

let cache_file cache_dir checksum =
  let rec aux acc = function
    | [f] -> OpamFilename.Op.(acc // f)
    | d::d1 -> aux OpamFilename.Op.(acc / d) d1
    | [] -> assert false
  in
  aux cache_dir (OpamHash.to_path checksum)

let fetch_from_cache cache_dir cache_urls checksums =
  let mismatch file =
    OpamConsole.error
      "Conflicting file hashes, or broken or compromised cache !\n%s"
      (OpamStd.Format.itemize (fun ck ->
           OpamHash.to_string ck ^
           if OpamHash.check_file (OpamFilename.to_string file) ck
           then OpamConsole.colorise `green " (match)"
           else OpamConsole.colorise `red " (MISMATCH)")
          checksums);
    OpamFilename.remove file;
    Done (Not_available "cache CONFLICT")
  in
  let dl_from_cache_job root_cache_url checksum file =
    let url = cache_url root_cache_url checksum in
    match url.OpamUrl.backend with
    | `http ->
      OpamDownload.download_as ~validate:false ~overwrite:true ~checksum
        url file
    | `rsync ->
      (OpamLocal.rsync_file url file @@| function
        | Result _ | Up_to_date _-> ()
        | Not_available m -> failwith m)
    | #OpamUrl.version_control ->
      failwith "Version control not allowed as cache URL"
  in
  try
    let hit_checksum, hit_file =
      OpamStd.List.find_map (fun ck ->
          let f = cache_file cache_dir ck in
          if OpamFilename.exists f then Some (ck, f) else None)
        checksums
    in
    if List.for_all
        (fun ck -> ck = hit_checksum ||
                   OpamHash.check_file (OpamFilename.to_string hit_file) ck)
        checksums
    then Done (Up_to_date (hit_file, OpamUrl.empty))
    else mismatch hit_file
  with Not_found -> match checksums with
    | [] -> Done (Not_available "cache miss")
    | checksum::_ ->
      (* Try all cache urls in order, but only the first checksum *)
      let local_file = cache_file cache_dir checksum in
      let tmpfile = OpamFilename.add_extension local_file "tmp" in
      let rec try_cache_dl = function
        | [] -> Done (Not_available "cache miss")
        | root_cache_url::other_caches ->
          OpamProcess.Job.catch
            (function Failure _ -> try_cache_dl other_caches
                    | e -> raise e)
          @@ fun () ->
          dl_from_cache_job root_cache_url checksum tmpfile
          @@+ fun () ->
          if List.for_all (OpamHash.check_file (OpamFilename.to_string tmpfile))
              checksums
          then
            (OpamFilename.move ~src:tmpfile ~dst:local_file;
             Done (Result (local_file, root_cache_url)))
          else mismatch tmpfile
      in
      try_cache_dl cache_urls

let validate_and_add_to_cache label url cache_dir file checksums =
  try
    let mismatch, expected =
      OpamStd.List.find_map (fun c ->
          match OpamHash.mismatch (OpamFilename.to_string file) c with
          | Some found -> Some (found, c)
          | None -> None)
        checksums
    in
    OpamConsole.error "%s: Checksum mismatch for %s:\n\
                      \  expected %s\n\
                      \  got      %s"
      label (OpamUrl.to_string url)
      (OpamHash.to_string expected)
      (OpamHash.to_string mismatch);
    OpamFilename.remove file;
    false
  with Not_found ->
    (match cache_dir, checksums with
     | Some dir, ck::_ ->
       OpamFilename.copy ~src:file ~dst:(cache_file dir ck)
       (* idea: hardlink to the other checksums ? *)
     | _ -> ());
    true

let pull_from_upstream label cache_dir destdir checksums url =
  let module B = (val url_backend url: OpamRepositoryBackend.S) in
  let cksum = match checksums with [] -> None | c::_ -> Some c in
  let text =
    OpamProcess.make_command_text label
      (OpamUrl.string_of_backend url.OpamUrl.backend)
  in
  OpamProcess.Job.with_text text @@
  B.pull_url destdir cksum url
  @@| function
  | (Result (F file) | Up_to_date (F file)) as ret ->
    if validate_and_add_to_cache label url cache_dir file checksums then
      (OpamConsole.msg "[%s] %s %s\n"
         (OpamConsole.colorise `green label)
         (if url.OpamUrl.backend = `http then "downloaded from"
          else "synchronised with")
         (OpamUrl.to_string url);
       ret)
    else
      Not_available "Checksum mismatch"
  | Result (D dir) | Up_to_date (D dir) ->
    if checksums = [] then Result (D dir) else
      (OpamConsole.error "%s: file checksum specified, but a directory was \
                          retrieved from %s"
         label (OpamUrl.to_string url);
       OpamFilename.rmdir dir;
       Not_available "can't check directory checksum")
  | Not_available r -> Not_available r

let rec pull_from_mirrors label cache_dir destdir checksums = function
  | [] -> invalid_arg "pull_from_mirrors: empty mirror list"
  | [url] -> pull_from_upstream label cache_dir destdir checksums url
  | url::mirrors ->
    pull_from_upstream label cache_dir destdir checksums url @@+ function
    | Not_available s ->
      OpamConsole.warning "%s: download of %s failed (%s), trying mirror"
        label (OpamUrl.to_string url) s;
      pull_from_mirrors label cache_dir destdir checksums mirrors
    | r -> Done r

let pull_url label ?cache_dir ?(cache_urls=[]) ?(silent_hits=false)
    local_dirname checksums remote_urls =
  (match cache_dir with
   | Some cache_dir ->
     let text = OpamProcess.make_command_text label "dl" in
     OpamProcess.Job.with_text text @@
     fetch_from_cache cache_dir cache_urls checksums
   | None ->
     assert (cache_urls = []);
     Done (Not_available "no cache"))
  @@+ function
  | Up_to_date (f, _) ->
    if not silent_hits then
      OpamConsole.msg "[%s] found in cache\n"
        (OpamConsole.colorise `green label);
    Done (Up_to_date (F f))
  | Result (f, url) ->
    OpamConsole.msg "[%s] downloaded from %s\n"
      (OpamConsole.colorise `green label)
      (OpamUrl.to_string url);
    Done (Result (F f))
  | Not_available _ ->
    if checksums = [] && OpamRepositoryConfig.(!r.force_checksums = Some true)
    then
      OpamConsole.error_and_exit
        "%s: Missing checksum, and `--require-checksums` was set."
        label;
    pull_from_mirrors label cache_dir local_dirname checksums remote_urls

let revision repo =
  let kind = repo.repo_url.OpamUrl.backend in
  let module B = (val find_backend_by_kind kind: OpamRepositoryBackend.S) in
  B.revision repo.repo_root

let pull_url_and_fix_digest label dirname checksums file url =
  pull_url label dirname [] url @@+ function
  | Not_available _
  | Up_to_date _
  | Result (D _) as r -> Done r
  | Result (F f) as r ->
    let fixed_checksums =
      List.map (fun c ->
          match OpamHash.mismatch (OpamFilename.to_string f) c with
          | Some actual ->
            OpamConsole.msg
              "Fixing wrong checksum for %s: current value is %s, setting it \
               to %s.\n"
              label (OpamHash.to_string c) (OpamHash.to_string actual);
            actual
          | None -> c)
        checksums
    in
    (if fixed_checksums <> checksums then
       let u = OpamFile.URL.read file in
       OpamFile.URL.write file (OpamFile.URL.with_checksum fixed_checksums u));
    Done r

let pull_file label ?cache_dir ?(cache_urls=[])  ?(silent_hits=false)
    file checksums remote_urls =
  (match cache_dir with
   | Some cache_dir ->
     let text = OpamProcess.make_command_text label "dl" in
     OpamProcess.Job.with_text text @@
     fetch_from_cache cache_dir cache_urls checksums
   | None ->
     assert (cache_urls = []);
     Done (Not_available "no cache"))
  @@+ function
  | Up_to_date (f, _) ->
    if not silent_hits then
      OpamConsole.msg "[%s] found in cache\n"
        (OpamConsole.colorise `green label);
    OpamFilename.copy ~src:f ~dst:file;
    Done (Result ())
  | Result (f, url) ->
    OpamConsole.msg "[%s] downloaded from %s\n"
      (OpamConsole.colorise `green label)
      (OpamUrl.to_string url);
    OpamFilename.copy ~src:f ~dst:file;
    Done (Result ())
  | Not_available _ ->
    if checksums = [] && OpamRepositoryConfig.(!r.force_checksums = Some true)
    then
      OpamConsole.error_and_exit
        "%s: Missing checksum, and `--require-checksums` was set."
        label;
    OpamFilename.with_tmp_dir_job (fun tmpdir ->
        pull_from_mirrors label cache_dir tmpdir checksums remote_urls
        @@| function
        | Up_to_date _ -> assert false
        | Result (F f) -> OpamFilename.move ~src:f ~dst:file; Result ()
        | Result (D _) -> Not_available "is a directory"
        | Not_available _ as na -> na)

let pull_file_to_cache label ~cache_dir ?(cache_urls=[]) checksums remote_urls =
  let text = OpamProcess.make_command_text label "dl" in
  OpamProcess.Job.with_text text @@
  fetch_from_cache cache_dir cache_urls checksums @@+ function
  | Up_to_date _ -> Done (Up_to_date ())
  | Result (_, url) ->
    OpamConsole.msg "[%s] downloaded from %s\n"
      (OpamConsole.colorise `green label)
      (OpamUrl.to_string url);
    Done (Result ())
  | Not_available _ ->
    OpamFilename.with_tmp_dir_job (fun tmpdir ->
        pull_from_mirrors label (Some cache_dir) tmpdir checksums remote_urls
        @@| function
        | Up_to_date _ -> assert false
        | Result (F _) -> Result ()
        | Result (D _) -> Not_available "is a directory"
        | Not_available _ as na -> na)

let packages r =
  OpamPackage.list (OpamRepositoryPath.packages_dir r.repo_root)

let packages_with_prefixes r =
  OpamPackage.prefixes (OpamRepositoryPath.packages_dir r.repo_root)

let validate_repo_update repo update =
  match
    repo.repo_trust,
    OpamRepositoryConfig.(!r.validation_hook),
    OpamRepositoryConfig.(!r.force_checksums)
  with
  | None, Some _, Some true ->
    OpamConsole.error
      "No trust anchors for repository %s, and security was enforced: \
       not updating"
      (OpamRepositoryName.to_string repo.repo_name);
    Done false
  | None, _, _ | _, None, _ | _, _, Some false ->
    Done true
  | Some ta, Some hook, _ ->
    let cmd =
      let open OpamRepositoryBackend in
      let env v = match OpamVariable.Full.to_string v, update with
        | "anchors", _ -> Some (S (String.concat "," ta.fingerprints))
        | "quorum", _ -> Some (S (string_of_int ta.quorum))
        | "repo", _ -> Some (S (OpamFilename.Dir.to_string repo.repo_root))
        | "patch", Update_patch f -> Some (S (OpamFilename.to_string f))
        | "incremental", Update_patch _ -> Some (B true)
        | "incremental", _ -> Some (B false)
        | "dir", Update_full d -> Some (S (OpamFilename.Dir.to_string d))
        | _ -> None
      in
      match OpamFilter.single_command env hook with
      | cmd::args ->
        OpamSystem.make_command
          ~name:"validation-hook"
          ~verbose:OpamCoreConfig.(!r.verbose_level >= 2)
          cmd args
      | [] -> failwith "Empty validation hook"
    in
    cmd @@> fun r ->
    log "validation: %s" (OpamProcess.result_summary r);
    Done (OpamProcess.is_success r)

open OpamRepositoryBackend

let apply_repo_update repo = function
  | Update_full d ->
    log "%a: applying update from scratch at %a"
      (slog OpamRepositoryName.to_string) repo.repo_name
      (slog OpamFilename.Dir.to_string) d;
    OpamFilename.rmdir repo.repo_root;
    if OpamFilename.is_symlink_dir d then
      (OpamFilename.copy_dir ~src:d ~dst:repo.repo_root;
       OpamFilename.rmdir d)
    else
      OpamFilename.move_dir ~src:d ~dst:repo.repo_root;
    OpamConsole.msg "[%s] Initialised\n"
      (OpamConsole.colorise `green
         (OpamRepositoryName.to_string repo.repo_name));
    Done ()
  | Update_patch f ->
    log "%a: applying patch update at %a"
      (slog OpamRepositoryName.to_string) repo.repo_name
      (slog OpamFilename.to_string) f;
    (OpamFilename.patch f repo.repo_root @@+ function
      | Some e ->
        if not (OpamConsole.debug ()) then OpamFilename.remove f;
        raise e
      | None -> OpamFilename.remove f; Done ())
  | Update_empty ->
    log "%a: applying empty update"
      (slog OpamRepositoryName.to_string) repo.repo_name;
    Done ()
  | Update_err _ -> assert false

let cleanup_repo_update = function
  | Update_full d -> OpamFilename.rmdir d
  | Update_patch f -> OpamFilename.remove f
  | _ -> ()

let update repo =
  log "update %a" (slog OpamRepositoryBackend.to_string) repo;
  let module B = (val find_backend repo: OpamRepositoryBackend.S) in
  B.fetch_repo_update repo.repo_name repo.repo_root repo.repo_url @@+ function
  | Update_err e -> raise e
  | Update_empty -> Done ()
  | (Update_full _ | Update_patch _) as upd ->
    OpamProcess.Job.catch (fun exn ->
        cleanup_repo_update upd;
        raise exn)
    @@ fun () ->
    validate_repo_update repo upd @@+ function
    | true -> apply_repo_update repo upd
    | false ->
      cleanup_repo_update upd;
      failwith "Invalid repository signatures, update aborted"
