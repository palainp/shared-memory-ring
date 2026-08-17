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

type ('a, 'b) t = {
  front : ('a, 'b) Direct_ring.Front.t;
  m : Miou.Mutex.t;
  c : Miou.Condition.t;
}

let of_front front =
  let t = { front; m = Miou.Mutex.create (); c = Miou.Condition.create () } in
  (* poll runs in the fibre that owns the ring, not in a signal handler, so
     broadcasting from here is an ordinary call between fibres. *)
  Direct_ring.Front.set_on_free front (fun () ->
      Miou.Mutex.protect t.m (fun () -> Miou.Condition.broadcast t.c));
  t

let front t = t.front
let wake t = Miou.Mutex.protect t.m (fun () -> Miou.Condition.broadcast t.c)

let wait_for_free t n =
  if n > Direct_ring.Front.nr_ents t.front then
    invalid_arg "Direct_miou.wait_for_free: more slots than the ring holds";
  Miou.Mutex.protect t.m (fun () ->
      while Direct_ring.Front.free_requests t.front < n do
        Miou.Condition.wait t.c t.m
      done)
