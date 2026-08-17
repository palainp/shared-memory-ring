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

(** Blocking on a full ring, under miou.

    This is the whole of what a scheduler has to supply to
    [shared-memory-ring-direct]: the rest of it never blocks. An Eio version of
    this file would be the same few lines with [Eio.Condition]. *)

type ('a, 'b) t

val of_front : ('a, 'b) Direct_ring.Front.t -> ('a, 'b) t
(** Attach to a client. This installs {!Direct_ring.Front.set_on_free}, so call
    it once and do not install a hook of your own afterwards. *)

val front : ('a, 'b) t -> ('a, 'b) Direct_ring.Front.t

val wait_for_free : ('a, 'b) t -> int -> unit
(** [wait_for_free t n] suspends the calling fibre until the ring has room for
    [n] more requests. The fibre that owns the ring must go on calling
    {!Direct_ring.Front.poll}, since that is what frees slots and wakes the
    sleepers.

    @raise Invalid_argument
      if [n] exceeds the size of the ring, which no amount of waiting would
      satisfy. *)

val wake : ('a, 'b) t -> unit
(** Wake every waiter, whether or not room appeared. Call this on shutdown so
    that nobody is left asleep on a ring that will never move again. *)
