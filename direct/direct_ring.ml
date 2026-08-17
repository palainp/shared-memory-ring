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

module Front = struct
  type 'a outcome = Reply of 'a | Shutdown

  exception Ring_full

  type ('a, 'b) t = {
    ring : ('a, 'b) Ring.Rpc.Front.t;
    waiting : ('b, 'a outcome -> unit) Hashtbl.t;
    (* Ids whose reply the peer follows with slots it never writes, one per
       extra descriptor the request carried. *)
    extras : ('b, int) Hashtbl.t;
    mutable skip : int; (* response slots still to step over *)
    mutable on_free : unit -> unit;
    mutable closed : bool;
    mutable unmatched : int;
  }

  let init ring =
    {
      ring;
      waiting = Hashtbl.create 64;
      extras = Hashtbl.create 8;
      skip = 0;
      on_free = ignore;
      closed = false;
      unmatched = 0;
    }

  let nr_ents t = Ring.Rpc.Front.nr_ents t.ring
  let free_requests t = Ring.Rpc.Front.get_free_requests t.ring
  let outstanding t = Hashtbl.length t.waiting
  let unmatched t = t.unmatched
  let set_on_free t fn = t.on_free <- fn
  let to_string t = Ring.Rpc.Front.to_string t.ring

  let slot t = Ring.Rpc.Front.slot t.ring (Ring.Rpc.Front.next_req_id t.ring)

  let write t ?(extras = []) ~on_reply req_fn =
    if t.closed then invalid_arg "Direct_ring.Front.write: ring is shut down";
    let n = List.length extras in
    if free_requests t < n + 1 then raise Ring_full;
    let id = req_fn (slot t) in
    List.iter (fun fill -> fill (slot t)) extras;
    Hashtbl.replace t.waiting id on_reply;
    if n > 0 then Hashtbl.replace t.extras id n

  let push t notify_fn =
    if Ring.Rpc.Front.push_requests_and_check_notify t.ring then notify_fn ()

  let poll t resp_fn =
    let freed = ref false in
    Ring.Rpc.Front.ack_responses t.ring (fun slot ->
        freed := true;
        if t.skip > 0 then t.skip <- t.skip - 1
        else
          let id, response = resp_fn slot in
          (* Read the extras before running the callback: it may write the next
             request and put the same id back in the table. *)
          (match Hashtbl.find_opt t.extras id with
          | Some n ->
              Hashtbl.remove t.extras id;
              t.skip <- n
          | None -> ());
          match Hashtbl.find_opt t.waiting id with
          | Some fn ->
              Hashtbl.remove t.waiting id;
              fn (Reply response)
          | None -> t.unmatched <- t.unmatched + 1);
    if !freed then t.on_free ()

  let shutdown t =
    t.closed <- true;
    (* Snapshot first: a callback is entitled to touch the table. *)
    let pending = Hashtbl.fold (fun _ fn acc -> fn :: acc) t.waiting [] in
    Hashtbl.reset t.waiting;
    Hashtbl.reset t.extras;
    t.skip <- 0;
    List.iter (fun fn -> fn Shutdown) pending
end
