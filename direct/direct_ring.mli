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

(** Direct-style interface to shared memory ring.

    What {!Lwt_ring} does with a promise per request, this does with a callback:
    [write] takes the function to run when the reply lands, and {!Front.poll}
    runs it. Nothing here blocks, so nothing here needs a scheduler, and this
    package depends only on [shared-memory-ring] itself.

    Waiting for room on a full ring is the one operation that has to block, and
    it is left to the caller: {!Front.free_requests} says how much room there
    is and {!Front.set_on_free} says when more appears. Under a scheduler with
    effects that is a handful of lines; [shared-memory-ring-direct-miou] has
    them. *)

open Ring

(** The (client) front-end connection to the shared ring. *)
module Front : sig
  type ('a, 'b) t
  (** Type of a frontend connection to a shared ring. ['a] is the response type,
      and ['b] is the request id type (e.g. int or int64). *)

  type 'a outcome =
    | Reply of 'a  (** the peer answered *)
    | Shutdown  (** the ring was shut down before it did *)
        (** What a request ends with. {!Lwt_ring} has the same two cases as the
            two ways its promise can finish, resolved or rejected with
            [Lwt_ring.Shutdown]; a callback needs them spelled out. *)

  exception Ring_full
  (** Raised by {!write} when no slot is free. Check {!free_requests}. *)

  val init : ('a, 'b) Ring.Rpc.Front.t -> ('a, 'b) t
  (** [init ring] is a stateful direct-style client attached to [ring]. Unlike
      {!Lwt_ring.Front.init} it takes no [string_of_id]: an id that matches no
      request is counted by {!unmatched} rather than printed. *)

  val write :
    ('a, 'b) t -> on_reply:('a outcome -> unit) -> (buf -> 'b) -> unit
  (** [write ring ~on_reply req_fn] claims a slot and calls [req_fn] on it,
      which marshals the request and returns its id. [on_reply] runs when the
      response carrying that id arrives, or when {!shutdown} is called,
      whichever comes first, and never twice.

      Nothing reaches the peer until {!push}.

      @raise Ring_full if the ring has no free slot. *)

  val push : ('a, 'b) t -> (unit -> unit) -> unit
  (** [push ring notify_fn] advances [ring] pointers, exposing the written
      requests to the other end. If the other end won't see the update,
      [notify_fn] is called to signal it. *)

  val poll : ('a, 'b) t -> (buf -> 'b * 'a) -> unit
  (** [poll ring resp_fn] polls the ring for responses and runs the callback
      registered for each id it finds. This can be called regularly, or
      triggered via some external event such as an event channel signal. *)

  val shutdown : ('a, 'b) t -> unit
  (** Run every outstanding callback with [Shutdown] and refuse further writes.
      A caller holding a resource on behalf of a request, a granted page for
      instance, gets it back this way. *)

  val free_requests : ('a, 'b) t -> int
  (** How many more requests may be written. *)

  val nr_ents : ('a, 'b) t -> int
  (** The size of the ring, and so the most requests that can ever be
      outstanding. *)

  val set_on_free : ('a, 'b) t -> (unit -> unit) -> unit
  (** [set_on_free ring fn] arranges for [fn] to run at the end of any {!poll}
      that freed at least one slot. This is the hook a scheduler needs in order
      to wake whoever is waiting on a full ring. *)

  val outstanding : ('a, 'b) t -> int
  (** Requests written whose reply has not arrived. *)

  val unmatched : ('a, 'b) t -> int
  (** Responses carrying an id no request claimed, since the ring was created.
      Zero unless the peer is misbehaving. Worth logging, never worth acting
      on. *)

  val to_string : ('a, 'b) t -> string
end
