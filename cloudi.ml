(*-*-Mode:ocaml;coding:utf-8;tab-width:2;c-basic-offset:2;indent-tabs-mode:()-*-
  ex: set ft=ocaml fenc=utf-8 sts=2 ts=2 sw=2 et nomod: *)

(*

  MIT License

  Copyright (c) 2017-2025 Michael Truog <mjtruog at protonmail dot com>

  Permission is hereby granted, free of charge, to any person obtaining a
  copy of this software and associated documentation files (the "Software"),
  to deal in the Software without restriction, including without limitation
  the rights to use, copy, modify, merge, publish, distribute, sublicense,
  and/or sell copies of the Software, and to permit persons to whom the
  Software is furnished to do so, subject to the following conditions:

  The above copyright notice and this permission notice shall be included in
  all copies or substantial portions of the Software.

  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
  FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
  DEALINGS IN THE SOFTWARE.

 *)

let message_init = 1
let message_send_async = 2
let message_send_sync = 3
let message_recv_async = 4
let message_return_async = 5
let message_return_sync = 6
let message_returns_async = 7
let message_keepalive = 8
let message_reinit = 9
let message_subscribe_count = 10
let message_term = 11

type request_type =
    ASYNC
  | SYNC
type source = Erlang.Pid.t

type response =
    Response of string
  | ResponseInfo of string * string
  | Forward of string * string * string
  | Forward_ of string * string * string * int * int
  | Null
  | NullError of string

type callback_result =
    ReturnI of string * string
  | ForwardI of string * string * string * int * int
  | Finished

module Instance = struct
  type 's t = {
      state : 's;
      terminate_exception : bool;
      socket : Unix.file_descr;
      use_header : bool;
      mutable initialization_complete : bool;
      mutable fatal_exceptions : bool;
      mutable terminate : bool;
      fragment_size : int;
      fragment_recv : bytes;
      callbacks : (string, (
        request_type ->
        string -> string ->
        string -> string ->
        int -> int -> string -> source ->
        's -> 's t ->
        response) Queue.t) Hashtbl.t;
      buffer_recv : Buffer.t;
      mutable process_index : int;
      mutable process_count : int;
      mutable process_count_max : int;
      mutable process_count_min : int;
      mutable prefix : string;
      mutable timeout_initialize : int;
      mutable timeout_async : int;
      mutable timeout_sync : int;
      mutable timeout_terminate : int;
      mutable priority_default : int;
      mutable response_info : string;
      mutable response : string;
      mutable trans_id : string;
      mutable trans_ids : string array;
      mutable subscribe_count : int;
    }
  let make ~state ~terminate_exception
    ~socket ~use_header ~fragment_size ~fragment_recv
    ~callbacks ~buffer_recv ~timeout_terminate =
    {state; terminate_exception; socket; use_header;
     initialization_complete = false;
     fatal_exceptions = false;
     terminate = false;
     fragment_size; fragment_recv; callbacks; buffer_recv;
     process_index = 0;
     process_count = 0;
     process_count_max = 0;
     process_count_min = 0;
     prefix = "";
     timeout_initialize = 0;
     timeout_async = 0;
     timeout_sync = 0;
     timeout_terminate;
     priority_default = 0;
     response_info = "";
     response = "";
     trans_id = "";
     trans_ids = Array.make 0 "";
     subscribe_count = 0}
  let init api process_index process_count
    process_count_max process_count_min prefix
    timeout_initialize timeout_async timeout_sync timeout_terminate
    priority_default fatal_exceptions =
    api.process_index <- process_index ;
    api.process_count <- process_count ;
    api.process_count_max <- process_count_max ;
    api.process_count_min <- process_count_min ;
    api.prefix <- prefix ;
    api.timeout_initialize <- timeout_initialize ;
    api.timeout_async <- timeout_async ;
    api.timeout_sync <- timeout_sync ;
    api.timeout_terminate <- timeout_terminate ;
    api.priority_default <- priority_default ;
    api.fatal_exceptions <- fatal_exceptions ;
    ()
  let reinit api process_count timeout_async timeout_sync
    priority_default fatal_exceptions =
    api.process_count <- process_count ;
    api.timeout_async <- timeout_async ;
    api.timeout_sync <- timeout_sync ;
    api.priority_default <- priority_default ;
    api.fatal_exceptions <- fatal_exceptions ;
    ()
  let set_response api response_info response trans_id =
    api.response_info <- response_info ;
    api.response <- response ;
    api.trans_id <- trans_id ;
    ()
  let set_trans_id api trans_id =
    api.trans_id <- trans_id ;
    ()
  let set_trans_ids api trans_ids_str trans_id_count =
    api.trans_ids <- Array.init trans_id_count (fun i ->
      String.sub trans_ids_str (i * 16) 16
    ) ;
    ()
  let set_subscribe_count api count =
    api.subscribe_count <- count ;
    ()
  let callbacks_add api pattern f =
    let key = api.prefix ^ pattern in
    let value = try Hashtbl.find api.callbacks key
    with Not_found -> (
      let value_new = Queue.create () in
      Hashtbl.add api.callbacks key value_new ;
      value_new)
    in
    Queue.push f value ;
    ()
  let callbacks_remove api pattern =
    let key = api.prefix ^ pattern in
    let value = Hashtbl.find api.callbacks key in
    let _f = Queue.pop value in
    if Queue.is_empty value then
      Hashtbl.remove api.callbacks key ;
    ()
end

type 's callback = (
  request_type ->
  string -> string ->
  string -> string ->
  int -> int -> string -> source ->
  's -> 's Instance.t ->
  response)

let trans_id_null = String.make 16 '\x00'

let invalid_input_error = "Invalid Input"
let message_decoding_error = "Message Decoding Error"
let terminate_error = "Terminate"

exception ReturnSync
exception ReturnAsync
exception ForwardSync
exception ForwardAsync
exception Terminate
exception FatalError

let print_exception str =
  prerr_endline ("Exception: " ^ str)

let print_error str =
  prerr_endline ("Error: " ^ str)

let str_replace input output =
  Str.global_replace (Str.regexp_string input) output

let str_split_on_char sep str =
  (* based on https://github.com/ocaml/ocaml/blob/trunk/stdlib/string.ml
   * (split_on_char) for use with OCaml 4.03.0
   *)
  let r = ref [] in
  let j = ref (String.length str) in
  for i = String.length str - 1 downto 0 do
    if str.[i] = sep then begin
      r := String.sub str (i + 1) (!j - i - 1) :: !r;
      j := i
    end
  done;
  String.sub str 0 !j :: !r

let list_append l1 l2 = List.rev_append (List.rev l1) l2

let backtrace (e : exn) : string =
  let indent = "  " in
  (Printexc.to_string e) ^ "\n" ^ indent ^
  (String.trim (str_replace "\n" ("\n" ^ indent) (Printexc.get_backtrace ())))

let null_response _ _ _ _ _ _ _ _ _ _ _ =
  Null

let getenv (name : string) : string =
  try Sys.getenv name
  with Not_found -> ""

let getenv_to_uint (name : string) : (int, string) result =
  let value = try int_of_string (Sys.getenv name)
    with _ -> -1
  in
  if value < 0 then
    Error (invalid_input_error)
  else
    Ok (value)

let fd_of_int (fd: int) : Unix.file_descr = Obj.magic fd

let unpack_uint32_native i binary : (int, string) result =
  let byte0 = int_of_char binary.[i + (if Sys.big_endian then 0 else 3)]
  and byte1 = int_of_char binary.[i + (if Sys.big_endian then 1 else 2)]
  and byte2 = int_of_char binary.[i + (if Sys.big_endian then 2 else 1)]
  and byte3 = int_of_char binary.[i + (if Sys.big_endian then 3 else 0)] in
  if byte0 > max_int lsr 24 then
    (* 32 bit system *)
    Error ("ocaml int overflow")
  else
    Ok (
      (byte0 lsl 24) lor (
        (byte1 lsl 16) lor (
          (byte2 lsl 8) lor byte3
        )
      )
    )

let unpack_int32_native i binary : (int, string) result =
  let byte0 = int_of_char binary.[i + (if Sys.big_endian then 0 else 3)]
  and byte1 = int_of_char binary.[i + (if Sys.big_endian then 1 else 2)]
  and byte2 = int_of_char binary.[i + (if Sys.big_endian then 2 else 1)]
  and byte3 = int_of_char binary.[i + (if Sys.big_endian then 3 else 0)] in
  let byte0u = 0x7f land byte0 in
  let byte0s = if (byte0 lsr 7) = 1 then
    -128 + byte0u
  else
    byte0u in
  if byte0u > max_int lsr 24 then
    (* 32 bit system *)
    Error ("ocaml int overflow")
  else
    Ok (
      (byte0s lsl 24) lor (
        (byte1 lsl 16) lor (
          (byte2 lsl 8) lor byte3
        )
      )
    )

let unpack_uint32_big i binary : (int, string) result =
  let byte0 = int_of_char binary.[i]
  and byte1 = int_of_char binary.[i + 1]
  and byte2 = int_of_char binary.[i + 2]
  and byte3 = int_of_char binary.[i + 3] in
  if byte0 > max_int lsr 24 then
    (* 32 bit system *)
    Error ("ocaml int overflow")
  else
    Ok (
      (byte0 lsl 24) lor (
        (byte1 lsl 16) lor (
          (byte2 lsl 8) lor byte3
        )
      )
    )

let unpack_uint8 i binary : int =
  int_of_char binary.[i]

let unpack_int8 i binary : int =
  let byte0 = int_of_char binary.[i] in
  if (byte0 lsr 7) = 1 then
    -128 + (0x7f land byte0)
  else
    byte0

let pack_uint32_big (value : int) buffer : unit =
  let byte0 = (value lsr 24) land 0xff
  and byte1 = (value lsr 16) land 0xff
  and byte2 = (value lsr 8) land 0xff
  and byte3 = value land 0xff in
  Buffer.add_char buffer (char_of_int byte0) ;
  Buffer.add_char buffer (char_of_int byte1) ;
  Buffer.add_char buffer (char_of_int byte2) ;
  Buffer.add_char buffer (char_of_int byte3)

let send {Instance.socket; use_header; _} data : (unit, string) result =
  let length = String.length data in
  let sent = if not use_header then
    (Unix.write_substring socket data 0 length) = length
  else (
    let total = 4 + length in
    let buffer = Buffer.create total in
    pack_uint32_big length buffer ;
    Buffer.add_string buffer data ;
    (Unix.write socket (Buffer.to_bytes buffer) 0 total) = total)
  in
  if sent then
    Ok (())
  else
    Error ("send failed")

let recv api : (string * int, string) result =
  let {Instance.socket; use_header;
    fragment_size; fragment_recv; buffer_recv; _} = api in
  if use_header then (
    let rec get_header () =
      if (Buffer.length buffer_recv) >= 4 then
        unpack_uint32_big 0 (Buffer.sub buffer_recv 0 4)
      else
        let i = Unix.read socket fragment_recv 0 fragment_size in
        if i = 0 then
          Error ("recv failed")
        else (
          Buffer.add_subbytes buffer_recv fragment_recv 0 i ;
          get_header ())
    in
    let rec get_body (total : int) =
      if (Buffer.length buffer_recv) >= total then (
        let data = (Buffer.sub buffer_recv 4 (total - 4))
        and data_remaining =
          Buffer.sub buffer_recv total ((Buffer.length buffer_recv) - total) in
        Buffer.clear buffer_recv ;
        Buffer.add_string buffer_recv data_remaining ;
        Ok (data))
      else
        let i = Unix.read socket fragment_recv 0 fragment_size in
        if i = 0 then
          Error ("recv failed")
        else (
          Buffer.add_subbytes buffer_recv fragment_recv 0 i ;
          get_body total)
    in
    match get_header () with
    | Error (error) ->
      Error (error)
    | Ok (length) ->
      match get_body (4 + length) with
      | Error (error) ->
        Error (error)
      | Ok (data) ->
        Ok ((data, length)))
  else (
    let rec get_body () =
      let i = Unix.read socket fragment_recv 0 fragment_size in
      Buffer.add_subbytes buffer_recv fragment_recv 0 i ;
      let ready = if i = fragment_size then
        let (reading, _, _) = Unix.select [socket] [] [] 0.0 in
        (List.length reading) > 0
      else
        false
      in
      if ready then
        get_body ()
      else (
        let data_all = Buffer.contents buffer_recv in
        Buffer.clear buffer_recv ;
        data_all)
    in
    let data = get_body () in
    if (String.length data) = 0 then
      Error ("recv failed")
    else
      Ok ((data, String.length data)))

let forward_async_i
  api name request_info request timeout priority trans_id source :
  (unit, string) result =
  match Erlang.term_to_binary (
    Erlang.OtpErlangTuple ([
      Erlang.OtpErlangAtom ("forward_async");
      Erlang.OtpErlangString (name);
      Erlang.OtpErlangBinary (request_info);
      Erlang.OtpErlangBinary (request);
      Erlang.OtpErlangInteger (timeout);
      Erlang.OtpErlangInteger (priority);
      Erlang.OtpErlangBinary (trans_id);
      Erlang.OtpErlangPid (source)])) with
  | Error (error) ->
    Error (error)
  | Ok (forward) ->
    send api forward

let forward_async
  api name request_info request timeout priority trans_id source :
  (unit, string) result =
  match forward_async_i
    api name request_info request timeout priority trans_id source with
  | Error (error) ->
    Error (error)
  | Ok _ ->
    raise ForwardAsync

let forward_sync_i
  api name request_info request timeout priority trans_id source :
  (unit, string) result =
  match Erlang.term_to_binary (
    Erlang.OtpErlangTuple ([
      Erlang.OtpErlangAtom ("forward_sync");
      Erlang.OtpErlangString (name);
      Erlang.OtpErlangBinary (request_info);
      Erlang.OtpErlangBinary (request);
      Erlang.OtpErlangInteger (timeout);
      Erlang.OtpErlangInteger (priority);
      Erlang.OtpErlangBinary (trans_id);
      Erlang.OtpErlangPid (source)])) with
  | Error (error) ->
    Error (error)
  | Ok (forward) ->
    send api forward

let forward_sync
  api name request_info request timeout priority trans_id source :
  (unit, string) result =
  match forward_sync_i
    api name request_info request timeout priority trans_id source with
  | Error (error) ->
    Error (error)
  | Ok _ ->
    raise ForwardSync

let forward_
  api request_type name request_info request timeout priority trans_id source :
  (unit, string) result =
  match request_type with
  | ASYNC ->
    forward_async api name request_info request
      timeout priority trans_id source
  | SYNC ->
    forward_sync api name request_info request
      timeout priority trans_id source

let return_async_i
  api name pattern response_info response timeout trans_id source :
  (unit, string) result =
  match Erlang.term_to_binary (
    Erlang.OtpErlangTuple ([
      Erlang.OtpErlangAtom ("return_async");
      Erlang.OtpErlangString (name);
      Erlang.OtpErlangString (pattern);
      Erlang.OtpErlangBinary (response_info);
      Erlang.OtpErlangBinary (response);
      Erlang.OtpErlangInteger (timeout);
      Erlang.OtpErlangBinary (trans_id);
      Erlang.OtpErlangPid (source)])) with
  | Error (error) ->
    Error (error)
  | Ok (return) ->
    send api return

let return_async
  api name pattern response_info response timeout trans_id source :
  (unit, string) result =
  match return_async_i
    api name pattern response_info response timeout trans_id source with
  | Error (error) ->
    Error (error)
  | Ok _ ->
    raise ReturnAsync

let return_sync_i
  api name pattern response_info response timeout trans_id source :
  (unit, string) result =
  match Erlang.term_to_binary (
    Erlang.OtpErlangTuple ([
      Erlang.OtpErlangAtom ("return_sync");
      Erlang.OtpErlangString (name);
      Erlang.OtpErlangString (pattern);
      Erlang.OtpErlangBinary (response_info);
      Erlang.OtpErlangBinary (response);
      Erlang.OtpErlangInteger (timeout);
      Erlang.OtpErlangBinary (trans_id);
      Erlang.OtpErlangPid (source)])) with
  | Error (error) ->
    Error (error)
  | Ok (return) ->
    send api return

let return_sync
  api name pattern response_info response timeout trans_id source :
  (unit, string) result =
  match return_sync_i
    api name pattern response_info response timeout trans_id source with
  | Error (error) ->
    Error (error)
  | Ok _ ->
    raise ReturnSync

let return_
  api request_type name pattern response_info response timeout trans_id source :
  (unit, string) result =
  match request_type with
  | ASYNC ->
    return_async api name pattern response_info response
      timeout trans_id source
  | SYNC ->
    return_sync api name pattern response_info response
      timeout trans_id source

let handle_events api ext data data_size i cmd : (bool, string) result =
  let i_cmd =
    if cmd = 0 then
      match unpack_uint32_native i data with
      | Error (error) ->
        Error (error)
      | Ok (value) ->
        Ok ((i + 4, value))
    else
      Ok ((i, cmd))
  in
  match i_cmd with
  | Error (error) ->
    Error (error)
  | Ok ((i0, cmd_value)) ->
    let rec loop i1 cmd_event =
      if cmd_event = message_term then (
        api.Instance.terminate <- true ;
        if ext then
          Ok (false)
        else
          Error (terminate_error))
      else if cmd_event = message_reinit then (
        match unpack_uint32_native i1 data with
        | Error (error) ->
          Error (error)
        | Ok (process_count) ->
          match unpack_uint32_native (i1 + 4) data with
          | Error (error) ->
            Error (error)
          | Ok (timeout_async) ->
            match unpack_uint32_native (i1 + 8) data with
            | Error (error) ->
              Error (error)
            | Ok (timeout_sync) ->
              let priority_default = unpack_int8 (i1 + 12) data
              and fatal_exceptions = (unpack_uint8 (i1 + 13) data) != 0
              and i2 = i1 + 14 in
              Instance.reinit api
                process_count
                timeout_async
                timeout_sync
                priority_default
                fatal_exceptions ;
              loop_cmd i2)
      else if cmd_event = message_keepalive then
        match Erlang.term_to_binary (Erlang.OtpErlangAtom ("keepalive")) with
        | Error (error) ->
          Error (error)
        | Ok (keepalive) ->
          match send api keepalive with
          | Error (error) ->
            Error (error)
          | Ok _ ->
            loop_cmd i1
      else
        Error (message_decoding_error)
    and loop_cmd i1 =
      if i1 > data_size then
        Error (message_decoding_error)
      else if i1 = data_size then
        Ok (true)
      else
        match unpack_uint32_native i1 data with
        | Error (error) ->
          Error (error)
        | Ok (cmd_next) ->
          loop (i1 + 4) cmd_next
    in
    loop i0 cmd_value

let rec poll_request_loop api timeout ext poll_timer: (bool, string) result =
  let {Instance.socket; buffer_recv; _} = api
  and timeout_value =
    if timeout < 0 then
      -1.0
    else if timeout = 0 then
      0.0
    else
      (float_of_int timeout) *. 0.001
  in
  let (reading, _, excepting) =
    if (Buffer.length buffer_recv) > 0 then
      ([socket], [], [])
    else
      Unix.select [socket] [] [socket] timeout_value
  in
  if (List.length excepting) > 0 then
    Ok (false)
  else if (List.length reading) = 0 then
    Ok (true)
  else
    match recv api with
    | Error (error) ->
      Error (error)
    | Ok (data, data_size) ->
      match poll_request_data api ext data data_size 0 with
      | Error (error) ->
        Error (error)
      | Ok (Some value) ->
        Ok (value)
      | Ok (None) ->
        let poll_timer_new =
          if timeout > 0 then
            Unix.gettimeofday ()
          else
            0.0
        in
        let timeout_new =
          if timeout > 0 then
            let elapsed = truncate
              ((poll_timer_new -. poll_timer) *. 1000.0) in
            if elapsed <= 0 then
              timeout
            else if elapsed >= timeout then
              0
            else
              timeout - elapsed
          else
            timeout
        in
        if timeout = 0 then
          Ok (true)
        else
          poll_request_loop api timeout_new ext poll_timer_new

and callback
  api request_type name pattern request_info request
  timeout priority trans_id source : (bool option, string) result =
  let {Instance.fatal_exceptions; state; callbacks; _} = api in
  let callback_get () =
    let function_queue = Hashtbl.find callbacks pattern in
    let f = Queue.pop function_queue in
    Queue.push f function_queue ;
    f
  in
  let callback_f =
    try callback_get ()
    with Not_found -> null_response
  in
  let callback_result_value =
    match request_type with
    | ASYNC -> (
      try Some (
        callback_f
          request_type name pattern request_info request
          timeout priority trans_id source state api)
      with
        | Terminate ->
          Some (Null)
        | ReturnAsync ->
          None
        | ReturnSync ->
          api.Instance.terminate <- true ;
          print_exception "Synchronous Call Return Invalid" ;
          None
        | ForwardAsync ->
          None
        | ForwardSync ->
          api.Instance.terminate <- true ;
          print_exception "Synchronous Call Forward Invalid" ;
          None
        | e ->
          print_exception (backtrace e) ;
          match e with
          | Assert_failure _ ->
            exit 1 ;
          | FatalError ->
            exit 1 ;
          | _ when fatal_exceptions ->
            exit 1 ;
          | _ ->
            Some (Null))
    | SYNC -> (
      try Some (
        callback_f
          request_type name pattern request_info request
          timeout priority trans_id source state api)
      with
        | Terminate ->
          Some (Null)
        | ReturnSync ->
          None
        | ReturnAsync ->
          api.Instance.terminate <- true ;
          print_exception "Asynchronous Call Return Invalid" ;
          None
        | ForwardSync ->
          None
        | ForwardAsync ->
          api.Instance.terminate <- true ;
          print_exception "Asynchronous Call Forward Invalid" ;
          None
        | e ->
          print_exception (backtrace e) ;
          match e with
          | Assert_failure _ ->
            exit 1 ;
          | FatalError ->
            exit 1 ;
          | _ when fatal_exceptions ->
            exit 1 ;
          | _ ->
            Some (Null))
  in
  let callback_result_type =
    match callback_result_value with
    | Some (ResponseInfo (v0, v1)) ->
      ReturnI (v0, v1)
    | Some (Response (v0)) ->
      ReturnI ("", v0)
    | Some (Forward (v0, v1, v2)) ->
      ForwardI (v0, v1, v2, timeout, priority)
    | Some (Forward_ (v0, v1, v2, v3, v4)) ->
      ForwardI (v0, v1, v2, v3, v4)
    | Some (Null) ->
      ReturnI ("", "")
    | Some (NullError (error)) ->
      print_error error ;
      ReturnI ("", "")
    | None ->
      Finished
  in
  let return_result =
    match request_type with
    | ASYNC -> (
      match callback_result_type with
      | Finished ->
        Ok (())
      | ReturnI (response_info, response) ->
        return_async_i
          api name pattern response_info response timeout trans_id source
      | ForwardI (name_, request_info_, request_, timeout_, priority_) ->
        forward_async_i
          api name_ request_info_ request_ timeout_ priority_ trans_id source)
    | SYNC -> (
      match callback_result_type with
      | Finished ->
        Ok (())
      | ReturnI (response_info, response) ->
        return_sync_i
          api name pattern response_info response timeout trans_id source
      | ForwardI (name_, request_info_, request_, timeout_, priority_) ->
        forward_sync_i
          api name_ request_info_ request_ timeout_ priority_ trans_id source)
  in
  match return_result with
  | Error (error) ->
    Error (error)
  | Ok _ ->
    Ok (None)

and poll_request_data api ext data data_size i : (bool option, string) result =
  match unpack_uint32_native i data with
  | Error (error) ->
    Error (error)
  | Ok (cmd) ->
    if cmd = message_init then
      match unpack_uint32_native (i + 4) data with
      | Error (error) ->
        Error (error)
      | Ok (process_index) ->
        match unpack_uint32_native (i + 8) data with
        | Error (error) ->
          Error (error)
        | Ok (process_count) ->
          match unpack_uint32_native (i + 12) data with
          | Error (error) ->
            Error (error)
          | Ok (process_count_max) ->
            match unpack_uint32_native (i + 16) data with
            | Error (error) ->
              Error (error)
            | Ok (process_count_min) ->
              match unpack_uint32_native (i + 20) data with
              | Error (error) ->
                Error (error)
              | Ok (prefix_size) ->
                let i0 = i + 24 in
                let prefix = String.sub data i0 (prefix_size - 1)
                and i1 = i0 + prefix_size in
                match unpack_uint32_native i1 data with
                | Error (error) ->
                  Error (error)
                | Ok (timeout_initialize) ->
                  match unpack_uint32_native (i1 + 4) data with
                  | Error (error) ->
                    Error (error)
                  | Ok (timeout_async) ->
                    match unpack_uint32_native (i1 + 8) data with
                    | Error (error) ->
                      Error (error)
                    | Ok (timeout_sync) ->
                      match unpack_uint32_native (i1 + 12) data with
                      | Error (error) ->
                        Error (error)
                      | Ok (timeout_terminate) ->
                        let priority_default =
                          unpack_int8 (i1 + 16) data
                        and fatal_exceptions =
                          (unpack_uint8 (i1 + 17) data) != 0 in
                        match unpack_int32_native (i1 + 18) data with
                        | Error (error) ->
                          Error (error)
                        | Ok (bind) ->
                          if bind >= 0 then
                            Error (invalid_input_error)
                          else
                            let i2 = i1 + 22 in
                            Instance.init api
                              process_index
                              process_count
                              process_count_max
                              process_count_min
                              prefix
                              timeout_initialize
                              timeout_async
                              timeout_sync
                              timeout_terminate
                              priority_default
                              fatal_exceptions ;
                            if i2 <> data_size then
                              match handle_events
                                api ext data data_size i2 0 with
                              | Error (error) ->
                                Error (error)
                              | Ok _ ->
                                Ok (Some false)
                            else
                              Ok (Some false)
    else if cmd = message_send_async || cmd = message_send_sync then
      match unpack_uint32_native (i + 4) data with
      | Error (error) ->
        Error (error)
      | Ok (name_size) ->
        let i0 = i + 8 in
        let name = String.sub data i0 (name_size - 1)
        and i1 = i0 + name_size in
        match unpack_uint32_native i1 data with
        | Error (error) ->
          Error (error)
        | Ok (pattern_size) ->
          let i2 = i1 + 4 in
          let pattern = String.sub data i2 (pattern_size - 1)
          and i3 = i2 + pattern_size in
          match unpack_uint32_native i3 data with
          | Error (error) ->
            Error (error)
          | Ok (request_info_size) ->
            let i4 = i3 + 4 in
            let request_info = String.sub data i4 request_info_size
            and i5 = i4 + request_info_size + 1 in
            match unpack_uint32_native i5 data with
            | Error (error) ->
              Error (error)
            | Ok (request_size) ->
              let i6 = i5 + 4 in
              let request = String.sub data i6 request_size
              and i7 = i6 + request_size + 1 in
              match unpack_uint32_native i7 data with
              | Error (error) ->
                Error (error)
              | Ok (timeout) ->
                let priority = unpack_int8 (i7 + 4) data
                and trans_id = String.sub data (i7 + 5) 16
                and i8 = i7 + 4 + 1 + 16 in
                match unpack_uint32_native i8 data with
                | Error (error) ->
                  Error (error)
                | Ok (source_size) ->
                  let i9 = i8 + 4 in
                  let source_data = String.sub data i9 source_size
                  and i10 = i9 + source_size in
                  match Erlang.binary_to_term source_data with
                  | Error (error) ->
                    Error (error)
                  | Ok (
                      Erlang.OtpErlangInteger _
                    | Erlang.OtpErlangIntegerBig _
                    | Erlang.OtpErlangFloat _
                    | Erlang.OtpErlangAtom _
                    | Erlang.OtpErlangAtomUTF8 _
                    | Erlang.OtpErlangAtomCacheRef _
                    | Erlang.OtpErlangAtomBool _
                    | Erlang.OtpErlangString _
                    | Erlang.OtpErlangBinary _
                    | Erlang.OtpErlangBinaryBits (_, _)
                    | Erlang.OtpErlangList _
                    | Erlang.OtpErlangListImproper _
                    | Erlang.OtpErlangTuple _
                    | Erlang.OtpErlangMap _
                    | Erlang.OtpErlangPort _
                    | Erlang.OtpErlangReference _
                    | Erlang.OtpErlangFunction _) ->
                    Error (message_decoding_error)
                  | Ok (Erlang.OtpErlangPid (source)) ->
                    let handled =
                      if i10 <> data_size then
                        handle_events api ext data data_size i10 0
                      else
                        Ok (true)
                    in
                    match handled with
                    | Error (error) ->
                      Error (error)
                    | Ok (false)  ->
                      Ok (Some false)
                    | Ok (true)  ->
                      let request_type =
                        if cmd = message_send_async then
                          ASYNC
                        else (* cmd = message_send_sync *)
                          SYNC
                      in
                      let callback_result =
                        callback
                          api request_type name pattern request_info request
                          timeout priority trans_id source in
                      if api.Instance.terminate then
                        Ok (Some false)
                      else
                        callback_result
    else if cmd = message_recv_async || cmd = message_return_sync then
      match unpack_uint32_native (i + 4) data with
      | Error (error) ->
        Error (error)
      | Ok (response_info_size) ->
        let i0 = i + 8 in
        let response_info = String.sub data i0 response_info_size
        and i1 = i0 + response_info_size + 1 in
        match unpack_uint32_native i1 data with
        | Error (error) ->
          Error (error)
        | Ok (response_size) ->
          let i2 = i1 + 4 in
          let response = String.sub data i2 response_size
          and i3 = i2 + response_size + 1 in
          let trans_id = String.sub data i3 16
          and i4 = i3 + 16 in
          Instance.set_response api
            response_info
            response
            trans_id ;
          if i4 <> data_size then
            match handle_events api ext data data_size i4 0 with
            | Error (error) ->
              Error (error)
            | Ok _ ->
              Ok (Some false)
          else
            Ok (Some false)
    else if cmd = message_return_async then (
      let i0 = i + 4 in
      let trans_id = String.sub data i0 16
      and i1 = i0 + 16 in
      Instance.set_trans_id api
        trans_id ;
      if i1 <> data_size then
        match handle_events api ext data data_size i1 0 with
        | Error (error) ->
          Error (error)
        | Ok _ ->
          Ok (Some false)
      else
        Ok (Some false))
    else if cmd = message_returns_async then
      match unpack_uint32_native (i + 4) data with
      | Error (error) ->
        Error (error)
      | Ok (trans_id_count) ->
        let i0 = i + 8
        and trans_ids_str_size = 16 * trans_id_count in
        let trans_ids_str = String.sub data i0 trans_ids_str_size
        and i1 = i0 + trans_ids_str_size in
        Instance.set_trans_ids api
          trans_ids_str
          trans_id_count ;
        if i1 <> data_size then
          match handle_events api ext data data_size i1 0 with
          | Error (error) ->
            Error (error)
          | Ok _ ->
            Ok (Some false)
        else
          Ok (Some false)
    else if cmd = message_subscribe_count then
      match unpack_uint32_native (i + 4) data with
      | Error (error) ->
        Error (error)
      | Ok (count) ->
        let i0 = i + 8 in
        Instance.set_subscribe_count api
          count ;
        if i0 <> data_size then
          match handle_events api ext data data_size i0 0 with
          | Error (error) ->
            Error (error)
          | Ok _ ->
            Ok (Some false)
        else
          Ok (Some false)
    else if cmd = message_term then
      match handle_events api ext data data_size (i + 4) cmd with
      | Error (error) ->
        Error (error)
      | Ok (true) ->
        Error (message_decoding_error)
      | Ok (false) ->
        Ok (Some false)
    else if cmd = message_reinit then
      match unpack_uint32_native (i + 4) data with
      | Error (error) ->
        Error (error)
      | Ok (process_count) ->
        match unpack_uint32_native (i + 8) data with
        | Error (error) ->
          Error (error)
        | Ok (timeout_async) ->
          match unpack_uint32_native (i + 12) data with
          | Error (error) ->
            Error (error)
          | Ok (timeout_sync) ->
            let priority_default = unpack_int8 (i + 16) data
            and fatal_exceptions = (unpack_uint8 (i + 17) data) != 0
            and i1 = i + 18 in
            Instance.reinit api
              process_count
              timeout_async
              timeout_sync
              priority_default
              fatal_exceptions ;
            if i1 = data_size then
              Ok (None)
            else if i1 < data_size then
              poll_request_data api ext data data_size i1
            else
              Error (message_decoding_error)
    else if cmd = message_keepalive then
      match Erlang.term_to_binary (Erlang.OtpErlangAtom ("keepalive")) with
      | Error (error) ->
        Error (error)
      | Ok (keepalive) ->
        match send api keepalive with
        | Error (error) ->
          Error (error)
        | Ok _ ->
          let i1 = i + 4 in
          if i1 = data_size then
            Ok (None)
          else if i1 < data_size then
            poll_request_data api ext data data_size i1
          else
            Error (message_decoding_error)
    else
      Error (message_decoding_error)

let poll_request api timeout ext : (bool, string) result =
  let {Instance.initialization_complete; terminate; _} = api in
  if terminate then
    if ext then
      Ok (false)
    else
      Error (terminate_error)
  else
    let poll_timer =
      if timeout > 0 then
        Unix.gettimeofday ()
      else
        0.0
    in
    if ext && not initialization_complete then (
      match Erlang.term_to_binary (Erlang.OtpErlangAtom ("polling")) with
      | Error (error) ->
        Error (error)
      | Ok (polling) ->
        match send api polling with
        | Error (error) ->
          Error (error)
        | Ok _ ->
          api.Instance.initialization_complete <- true ;
          poll_request_loop api timeout ext poll_timer)
    else
      poll_request_loop api timeout ext poll_timer

let api
  ?terminate_return_value:(terminate_return_value = true)
  (thread_index : int) (state : 's): ('s Instance.t, string) result =
  let protocol = getenv "CLOUDI_API_INIT_PROTOCOL" in
  if protocol = "" then (
    prerr_endline "CloudI service execution must occur in CloudI" ;
    Error (invalid_input_error))
  else
    match getenv_to_uint "CLOUDI_API_INIT_BUFFER_SIZE" with
      | Error (error) ->
        Error (error)
      | Ok (buffer_size) ->
        let terminate_exception = not terminate_return_value
        and socket_high = fd_of_int (thread_index + 1024)
        and socket_low = fd_of_int (thread_index + 3)
        and use_header = (protocol <> "udp")
        and fragment_size = buffer_size
        and fragment_recv = Bytes.create buffer_size
        and callbacks = Hashtbl.create 1024
        and buffer_recv = Buffer.create buffer_size
        and timeout_terminate = 10 (* TIMEOUT_TERMINATE_MIN *) in
        Unix.dup2 socket_high socket_low ;
        let api = Instance.make
          ~state:state
          ~terminate_exception:terminate_exception
          ~socket:socket_low
          ~use_header:use_header
          ~fragment_size:fragment_size
          ~fragment_recv:fragment_recv
          ~callbacks:callbacks
          ~buffer_recv:buffer_recv
          ~timeout_terminate:timeout_terminate in
        match Erlang.term_to_binary (Erlang.OtpErlangAtom ("init")) with
        | Error (error) ->
          Error (error)
        | Ok (init) ->
          match send api init with
          | Error (error) ->
            Error (error)
          | Ok _ ->
            match poll_request api (-1) false with
            | Error (error) ->
              (* Terminate exception not used here *)
              Error (error)
            | Ok _ ->
              Ok (api)

let thread_count () : (int, string) result =
  getenv_to_uint "CLOUDI_API_INIT_THREAD_COUNT"

let subscribe api pattern f =
  match Erlang.term_to_binary (
    Erlang.OtpErlangTuple ([
      Erlang.OtpErlangAtom ("subscribe");
      Erlang.OtpErlangString (pattern)])) with
  | Error (error) ->
    Error (error)
  | Ok (subscribe) ->
    match send api subscribe with
    | Error (error) ->
      Error (error)
    | Ok _ ->
      Instance.callbacks_add api pattern f ;
      Ok (())

let subscribe_count api pattern =
  match Erlang.term_to_binary (
    Erlang.OtpErlangTuple ([
      Erlang.OtpErlangAtom ("subscribe_count");
      Erlang.OtpErlangString (pattern)])) with
  | Error (error) ->
    Error (error)
  | Ok (subscribe_count) ->
    match send api subscribe_count with
    | Error (error) ->
      Error (error)
    | Ok _ ->
      match poll_request api (-1) false with
      | Error (error) ->
        if error = terminate_error && api.Instance.terminate_exception then
          raise Terminate
        else
          Error (error)
      | Ok _ ->
        Ok (api.Instance.subscribe_count)

let unsubscribe api pattern =
  match Erlang.term_to_binary (
    Erlang.OtpErlangTuple ([
      Erlang.OtpErlangAtom ("unsubscribe");
      Erlang.OtpErlangString (pattern)])) with
  | Error (error) ->
    Error (error)
  | Ok (unsubscribe) ->
    match send api unsubscribe with
    | Error (error) ->
      Error (error)
    | Ok _ ->
      Instance.callbacks_remove api pattern ;
      Ok (())

let send_async
  ?timeout:(timeout_arg = -1)
  ?request_info:(request_info = "")
  ?priority:(priority_arg = 256)
  api name request =
  let timeout =
    if timeout_arg = -1 then
      api.Instance.timeout_async
    else
      timeout_arg
  and priority =
    if priority_arg = 256 then
      api.Instance.priority_default
    else
      priority_arg
  in
  match Erlang.term_to_binary (
    Erlang.OtpErlangTuple ([
      Erlang.OtpErlangAtom ("send_async");
      Erlang.OtpErlangString (name);
      Erlang.OtpErlangBinary (request_info);
      Erlang.OtpErlangBinary (request);
      Erlang.OtpErlangInteger (timeout);
      Erlang.OtpErlangInteger (priority)])) with
  | Error (error) ->
    Error (error)
  | Ok (send_async) ->
    match send api send_async with
    | Error (error) ->
      Error (error)
    | Ok _ ->
      match poll_request api (-1) false with
      | Error (error) ->
        if error = terminate_error && api.Instance.terminate_exception then
          raise Terminate
        else
          Error (error)
      | Ok _ ->
        Ok (api.Instance.trans_id)

let send_sync
  ?timeout:(timeout_arg = -1)
  ?request_info:(request_info = "")
  ?priority:(priority_arg = 256)
  api name request =
  let timeout =
    if timeout_arg = -1 then
      api.Instance.timeout_sync
    else
      timeout_arg
  and priority =
    if priority_arg = 256 then
      api.Instance.priority_default
    else
      priority_arg
  in
  match Erlang.term_to_binary (
    Erlang.OtpErlangTuple ([
      Erlang.OtpErlangAtom ("send_sync");
      Erlang.OtpErlangString (name);
      Erlang.OtpErlangBinary (request_info);
      Erlang.OtpErlangBinary (request);
      Erlang.OtpErlangInteger (timeout);
      Erlang.OtpErlangInteger (priority)])) with
  | Error (error) ->
    Error (error)
  | Ok (send_sync) ->
    match send api send_sync with
    | Error (error) ->
      Error (error)
    | Ok _ ->
      match poll_request api (-1) false with
      | Error (error) ->
        if error = terminate_error && api.Instance.terminate_exception then
          raise Terminate
        else
          Error (error)
      | Ok _ ->
        Ok ((
          api.Instance.response_info,
          api.Instance.response,
          api.Instance.trans_id))

let mcast_async
  ?timeout:(timeout_arg = -1)
  ?request_info:(request_info = "")
  ?priority:(priority_arg = 256)
  api name request =
  let timeout =
    if timeout_arg = -1 then
      api.Instance.timeout_async
    else
      timeout_arg
  and priority =
    if priority_arg = 256 then
      api.Instance.priority_default
    else
      priority_arg
  in
  match Erlang.term_to_binary (
    Erlang.OtpErlangTuple ([
      Erlang.OtpErlangAtom ("mcast_async");
      Erlang.OtpErlangString (name);
      Erlang.OtpErlangBinary (request_info);
      Erlang.OtpErlangBinary (request);
      Erlang.OtpErlangInteger (timeout);
      Erlang.OtpErlangInteger (priority)])) with
  | Error (error) ->
    Error (error)
  | Ok (mcast_async) ->
    match send api mcast_async with
    | Error (error) ->
      Error (error)
    | Ok _ ->
      match poll_request api (-1) false with
      | Error (error) ->
        if error = terminate_error && api.Instance.terminate_exception then
          raise Terminate
        else
          Error (error)
      | Ok _ ->
        Ok (api.Instance.trans_ids)

let recv_async
  ?timeout:(timeout_arg = -1)
  ?trans_id:(trans_id = trans_id_null)
  ?consume:(consume = true)
  api =
  let timeout =
    if timeout_arg = -1 then
      api.Instance.timeout_sync
    else
      timeout_arg
  in
  match Erlang.term_to_binary (
    Erlang.OtpErlangTuple ([
      Erlang.OtpErlangAtom ("recv_async");
      Erlang.OtpErlangInteger (timeout);
      Erlang.OtpErlangBinary (trans_id);
      Erlang.OtpErlangAtomBool (consume)])) with
  | Error (error) ->
    Error (error)
  | Ok (recv_async) ->
    match send api recv_async with
    | Error (error) ->
      Error (error)
    | Ok _ ->
      match poll_request api (-1) false with
      | Error (error) ->
        if error = terminate_error && api.Instance.terminate_exception then
          raise Terminate
        else
          Error (error)
      | Ok _ ->
        Ok ((
          api.Instance.response_info,
          api.Instance.response,
          api.Instance.trans_id))

let process_index (api : 's Instance.t) : int =
  api.Instance.process_index

let process_index_ () : (int, string) result =
  getenv_to_uint "CLOUDI_API_INIT_PROCESS_INDEX"

let process_count (api : 's Instance.t) : int =
  api.Instance.process_count

let process_count_max (api : 's Instance.t) : int =
  api.Instance.process_count_max

let process_count_max_ () : (int, string) result =
  getenv_to_uint "CLOUDI_API_INIT_PROCESS_COUNT_MAX"

let process_count_min (api : 's Instance.t) : int =
  api.Instance.process_count_min

let process_count_min_ () : (int, string) result =
  getenv_to_uint "CLOUDI_API_INIT_PROCESS_COUNT_MIN"

let prefix (api : 's Instance.t) : string =
  api.Instance.prefix

let timeout_initialize (api : 's Instance.t) : int =
  api.Instance.timeout_initialize

let timeout_initialize_ () : (int, string) result =
  getenv_to_uint "CLOUDI_API_INIT_TIMEOUT_INITIALIZE"

let timeout_async (api : 's Instance.t) : int =
  api.Instance.timeout_async

let timeout_sync (api : 's Instance.t) : int =
  api.Instance.timeout_sync

let timeout_terminate (api : 's Instance.t) : int =
  api.Instance.timeout_terminate

let timeout_terminate_ () : (int, string) result =
  getenv_to_uint "CLOUDI_API_INIT_TIMEOUT_TERMINATE"

let priority_default (api : 's Instance.t) : int =
  api.Instance.priority_default

let poll (api : 's Instance.t) (timeout : int) : (bool, string) result =
  poll_request api timeout true

let shutdown
  ?reason:(reason = "")
  api =
  match Erlang.term_to_binary (
    Erlang.OtpErlangTuple ([
      Erlang.OtpErlangAtom ("shutdown");
      Erlang.OtpErlangString (reason)])) with
  | Error (error) ->
    Error (error)
  | Ok (shutdown) ->
    match send api shutdown with
    | Error (error) ->
      Error (error)
    | Ok _ ->
      Ok (())

let text_pairs_parse text : (string, string list) Hashtbl.t =
  let pairs = Hashtbl.create 32
  and data = str_split_on_char '\x00' text in
  let rec loop = function
  | [] ->
    pairs
  | [""] ->
    pairs
  | key::t0 ->
    match t0 with
    | [] ->
      raise Exit
    | value::t1 -> (
      try
        let l = Hashtbl.find pairs key in
        Hashtbl.replace pairs key (list_append l [value])
      with Not_found ->
        Hashtbl.add pairs key [value]) ;
      loop t1
  in
  loop data

let text_pairs_new pairs response : string =
  let buffer = Buffer.create 1024 in
  if response && Hashtbl.length pairs = 0 then
    Buffer.add_char buffer '\x00'
  else
    Hashtbl.iter (fun key values ->
      let rec loop = function
        | [] ->
          ()
        | h::t ->
          Buffer.add_string buffer key ;
          Buffer.add_char buffer '\x00' ;
          Buffer.add_string buffer h ;
          Buffer.add_char buffer '\x00' ;
          loop t
      in
      loop values
    ) pairs ;
  Buffer.contents buffer

let info_key_value_parse info =
  text_pairs_parse info

let info_key_value_new
  ?response:(response = true) pairs =
  text_pairs_new pairs response

