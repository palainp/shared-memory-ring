(*
 * Copyright (c) 2026 Pierre Alain <piertre.alain@tuta.io>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open OUnit

let alloc_page () = Bigarray.Array1.create Bigarray.char Bigarray.c_layout 4096

(* lwt_test/lwt_test.ml's one_request_response, step for step, with the
   callback in place of the promise: where the original checked that the thread
   had stopped sleeping, this checks that the callback ran. *)
let one_request_response () =
  let page = alloc_page () in
  let sring =
    Ring.Rpc.of_buf ~buf:(Cstruct.of_bigarray page) ~idx_size:1 ~name:"test"
  in
  let front = Ring.Rpc.Front.init ~sring in
  let back = Ring.Rpc.Back.init ~sring in

  assert_equal ~msg:"more_to_do" ~printer:string_of_bool false
    (Ring.Rpc.Back.more_to_do back);

  let client = Direct_ring.Front.init front in

  let id = () in
  let must_notify = ref false in
  let replied = ref false in
  Direct_ring.Front.write client
    ~on_reply:(function
      | Direct_ring.Front.Reply () -> replied := true
      | Direct_ring.Front.Shutdown -> ())
    (fun _ -> id);
  Direct_ring.Front.push client (fun () -> must_notify := true);
  assert_equal ~msg:"must_notify" ~printer:string_of_bool true !must_notify;
  assert_equal ~msg:"more_to_do" ~printer:string_of_bool true
    (Ring.Rpc.Back.more_to_do back);

  let finished = ref false in
  Ring.Rpc.Back.ack_requests back (fun _ -> finished := true);
  assert_equal ~msg:"ack_requests" ~printer:string_of_bool true !finished;

  ignore (Ring.Rpc.Back.next_res_id back);
  ignore (Ring.Rpc.Back.push_responses_and_check_notify back);

  Direct_ring.Front.poll client (fun _ -> (id, ()));
  assert_equal ~msg:"poll" ~printer:string_of_bool true !replied;

  assert_equal ~msg:"more_to_do" ~printer:string_of_bool false
    (Ring.Rpc.Back.more_to_do back);
  assert_equal ~msg:"outstanding" ~printer:string_of_int 0
    (Direct_ring.Front.outstanding client)

(* An extra descriptor is consumed by the peer but not answered: it advances the
   response producer past that slot without writing to it. Poison the slot it
   will step over, so that reading it as a reply would name a request nobody
   made. *)
let extra_descriptor () =
  let page = alloc_page () in
  let buf = Cstruct.of_bigarray page in
  let sring = Ring.Rpc.of_buf ~buf ~idx_size:16 ~name:"test" in
  let front = Ring.Rpc.Front.init ~sring in
  let back = Ring.Rpc.Back.init ~sring in
  let client = Direct_ring.Front.init front in

  Cstruct.set_uint8 (Ring.Rpc.Front.slot front 1) 0 99;

  let replied = ref 0 in
  Direct_ring.Front.write client
    ~extras:[ (fun slot -> Cstruct.set_uint8 slot 0 200) ]
    ~on_reply:(function
      | Direct_ring.Front.Reply () -> incr replied
      | Direct_ring.Front.Shutdown -> ())
    (fun slot ->
      Cstruct.set_uint8 slot 0 8;
      8);
  Direct_ring.Front.push client ignore;
  assert_equal ~msg:"two slots taken" ~printer:string_of_int
    (Ring.Rpc.Front.nr_ents front - 2)
    (Direct_ring.Front.free_requests client);

  (* The peer: read both slots, answer the request once, step over one
     response slot without writing it. *)
  Ring.Rpc.Back.ack_requests back (fun _ -> ());
  Cstruct.set_uint8 (Ring.Rpc.Back.slot back (Ring.Rpc.Back.next_res_id back)) 0 8;
  ignore (Ring.Rpc.Back.next_res_id back);
  ignore (Ring.Rpc.Back.push_responses_and_check_notify back);

  Direct_ring.Front.poll client (fun slot -> (Cstruct.get_uint8 slot 0, ()));
  assert_equal ~msg:"the reply came back" ~printer:string_of_int 1 !replied;
  assert_equal ~msg:"the poisoned slot was stepped over" ~printer:string_of_int 0
    (Direct_ring.Front.unmatched client);
  assert_equal ~msg:"both slots are free again" ~printer:string_of_int
    (Ring.Rpc.Front.nr_ents front)
    (Direct_ring.Front.free_requests client)


(* Shutdown hands every outstanding request back to whoever wrote it, the way
   Lwt_ring.Front.shutdown rejects every pending promise. *)
let shutdown_hands_requests_back () =
  let page = alloc_page () in
  let sring =
    Ring.Rpc.of_buf ~buf:(Cstruct.of_bigarray page) ~idx_size:16 ~name:"test"
  in
  let front = Ring.Rpc.Front.init ~sring in
  let client = Direct_ring.Front.init front in
  let outcome = ref None in
  Direct_ring.Front.write client
    ~on_reply:(fun o -> outcome := Some o)
    (fun _ -> 9);
  Direct_ring.Front.shutdown client;
  assert_equal ~msg:"the callback ran" ~printer:string_of_bool true
    (!outcome = Some Direct_ring.Front.Shutdown);
  assert_equal ~msg:"nothing left outstanding" ~printer:string_of_int 0
    (Direct_ring.Front.outstanding client)

let _ =
  let verbose = ref false in
  Arg.parse
    [ ("-verbose", Arg.Unit (fun _ -> verbose := true), "Run in verbose mode") ]
    (fun x -> Printf.fprintf stderr "Ignoring argument: %s" x)
    "Test the direct-style shared memory ring client";

  let suite =
    "direct"
    >::: [
           "one_request_response" >:: one_request_response;
           "extra_descriptor" >:: extra_descriptor;
           "shutdown_hands_requests_back" >:: shutdown_hands_requests_back;
         ]
  in
  run_test_tt ~verbose:!verbose suite
