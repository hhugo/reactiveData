(* ReactiveData
 * https://github.com/hhugo/reactiveData
 * Copyright (C) 2014 Hugo Heuzard
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, with linking exception;
 * either version 2.1 of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
 *)

module type DATA = sig
  type 'a data
  type 'a patch
  val merge : 'a patch -> 'a data -> 'a data
  val map_patch : ('a -> 'b) -> 'a patch -> 'b patch
  val map_data : ('a -> 'b) -> 'a data -> 'b data
  val empty : 'a data
end
module type S = sig
  type 'a data
  type 'a patch
  type 'a msg = Patch of 'a patch | Set of 'a data
  type 'a handle
  type 'a t
  val empty : 'a t
  val make : 'a data -> 'a t * 'a handle
  val make_from : 'a data -> 'a msg React.E.t -> 'a t
  val make_from_s : 'a data React.S.t -> 'a t
  val const : 'a data -> 'a t
  val patch : 'a handle -> 'a patch -> unit
  val set   : 'a handle -> 'a data -> unit
  val map_msg : ('a -> 'b) -> 'a msg -> 'b msg
  val map : ('a -> 'b) -> 'a t -> 'b t
  val value : 'a t -> 'a data
  val fold : ('a -> 'b msg -> 'a) -> 'b t -> 'a -> 'a React.signal
  val value_s : 'a t -> 'a data React.S.t
  val event : 'a t -> 'a msg React.E.t
end
module Make(D : DATA) :
  S with type 'a data = 'a D.data
     and type 'a patch = 'a D.patch = struct

  type 'a data = 'a D.data
  type 'a patch = 'a D.patch
  let merge = D.merge
  let map_patch = D.map_patch
  let map_data = D.map_data

  type 'a msg =
    | Patch of 'a patch
    | Set of 'a data

  type 'a handle = ?step:React.step -> 'a msg -> unit

  type 'a mut = {
    current : 'a data ref;
    event : 'a msg React.E.t;
  }

  type 'a t =
    | Const of 'a data
    | Mut of 'a mut

  let empty = Const D.empty

  let make l =
    let initial_event,send = React.E.create () in
    let current = ref l in
    let event = React.E.map (fun msg ->
        begin match msg with
          | Set l -> current := l;
          | Patch p -> current := merge p !current
        end;
        msg) initial_event in
    Mut {current;event},send

  let make_from l initial_event =
    let current = ref l in
    let event = React.E.map (fun msg ->
        begin match msg with
          | Set l -> current := l;
          | Patch p -> current := merge p !current
        end;
        msg) initial_event in
    Mut {current;event}

  let const x = Const x

  let map_msg (f : 'a -> 'b) : 'a msg -> 'b msg = function
    | Set l -> Set (map_data f l)
    | Patch p -> Patch (map_patch f p)

  let map f s =
    match s with
    | Const x -> Const (map_data f x)
    | Mut s ->
      let current = ref (map_data f !(s.current)) in
      let event = React.E.map (fun msg ->
          let msg = map_msg f msg in
          begin match msg with
            | Set l -> current := l;
            | Patch p -> current := merge p !current
          end;
          msg) s.event in
      Mut {current ;event}

  let value s = match s with
    | Const c -> c
    | Mut s -> !(s.current)

  let event s = match s with
    | Const _ -> React.E.never
    | Mut s -> s.event

  let patch (s : 'a handle) p = s (Patch p)

  let set (s : 'a handle) p = s (Set p)

  let fold f s acc =
    match s with
    | Const c -> React.S.const (f acc (Set c))
    | Mut s ->
      let acc = f acc (Set (!(s.current))) in
      React.S.fold f acc s.event

  let value_s (s : 'a t) : 'a data React.S.t =
    match s with
    | Const c -> React.S.const c
    | Mut s ->
      React.S.fold (fun l msg ->
          match msg with
          | Set l -> l
          | Patch p -> merge p l) (!(s.current)) s.event

  let make_from_s s =
    make_from (React.S.value s) (React.E.map (fun e -> Set e) (React.S.changes s))

end

module DataList = struct
  type 'a data = 'a list
  type 'a p =
    | I of int * 'a
    | R of int
    | U of int * 'a
    | X of int * int
  type 'a patch = 'a p list
  let empty = []
  let map_data = List.map
  let map_patch f = function
    | I (i,x) -> I (i, f x)
    | R i -> R i
    | X (i,j) -> X (i,j)
    | U (i,x) -> U (i,f x)
  let map_patch f = List.map (map_patch f)

  let merge_p op l =
    match op with
    | I (i',x) ->
      let i = if i' < 0 then List.length l + 1 + i' else i' in
      let rec aux acc n l = match n,l with
        | 0,l -> List.rev_append acc (x::l)
        | _,[] -> failwith "ReactiveData.Rlist.merge"
        | n,x::xs -> aux (x::acc) (pred n) xs
      in aux [] i l
    | R i' ->
      let i = if i' < 0 then List.length l + i' else i' in
      let rec aux acc n l = match n,l with
        | 0,x::l -> List.rev_append acc l
        | _,[] -> failwith "ReactiveData.Rlist.merge"
        | n,x::xs -> aux (x::acc) (pred n) xs
      in aux [] i l
    | U (i',x) ->
      let i = if i' < 0 then List.length l + i' else i' in
      let a = Array.of_list l in
      a.(i) <- x;
      Array.to_list a
    | X (i',offset) ->
      let a = Array.of_list l in
      let len = Array.length a in
      let i = if i' < 0 then len + i' else i' in
      let v = a.(i) in
      if offset > 0
      then begin
        if (i + offset >= len) then failwith "ReactiveData.Rlist.merge";
        for j = i to i + offset - 1 do
          a.(j) <- a.(j + 1)
        done;
        a.(i+offset) <- v
      end
      else begin
        if (i + offset < 0) then failwith "ReactiveData.Rlist.merge";
        for j = i downto i + offset + 1 do
          a.(j) <- a.(j - 1)
        done;
        a.(i+offset) <- v
      end;
      Array.to_list a

  let merge p l = List.fold_left (fun l x -> merge_p x l) l p
end

module RList = struct
  include Make (DataList)
  module D = DataList
  type 'a p = 'a D.p =
    | I of int * 'a
    | R of int
    | U of int * 'a
    | X of int * int

  let nil = empty
  let append x s = patch s [D.I (-1,x)]
  let cons x s = patch s [D.I (0,x)]
  let insert x i s = patch s [D.I (i,x)]
  let update x i s = patch s [D.U (i,x)]
  let move i j s = patch s [D.X (i,j)]
  let remove i s = patch s [D.R i]

  let singleton x = const [x]

  let singleton_s s =
    let first = ref true in
    let e,send = React.E.create () in
    let result = make_from [] e in
    let _ = React.S.map (fun x ->
        if !first
        then begin
          first:=false;
          send (Patch [I(0,x)])
        end
        else send (Patch [U(0,x)])) s in
    result

  let concat : 'a t -> 'a t -> 'a t = fun x y ->
    let v1 = value x
    and v2 = value y in
    let size1 = ref 0
    and size2 = ref 0 in
    let size_with_patch sizex : 'a D.p -> unit = function
      | (D.I _) -> incr sizex
      | (D.R _) -> decr sizex
      | (D.X _ | D.U _) -> () in
    let size_with_set sizex l = sizex:=List.length l in

    size_with_set size1 v1;
    size_with_set size2 v2;

    let update_patch1 = List.map (fun p ->
        let m = match p with
          | D.I (pos,x) ->
            let i = if pos < 0 then pos - !size2 else pos in
            D.I (i, x)
          | D.R pos     -> D.R  (if pos < 0 then pos - !size2 else pos)
          | D.U (pos,x) -> D.U ((if pos < 0 then pos - !size2 else pos), x)
          | D.X (i,j) ->   D.X ((if i < 0 then i - !size2 else i),j)
        in
        size_with_patch size1 m;
        m) in
    let update_patch2 = List.map (fun p ->
        let m = match p with
          | D.I (pos,x) -> D.I ((if pos < 0 then pos else !size1 + pos), x)
          | D.R pos     -> D.R  (if pos < 0 then pos else !size1 + pos)
          | D.U (pos,x) -> D.U ((if pos < 0 then pos else !size1 + pos), x)
          | D.X (i,j) ->   D.X ((if i < 0 then i else !size1 + i),j)
        in
        size_with_patch size2 m;
        m) in
    let tuple_ev =
      React.E.merge (fun acc x ->
          match acc,x with
          | (None,p2),`E1 x -> Some x,p2
          | (p1,None),`E2 x -> p1, Some x
          | _ -> assert false)
        (None,None)
        [React.E.map (fun e -> `E1 e) (event x);
         React.E.map (fun e -> `E2 e) (event y)] in
    let merged_ev = React.E.map (fun p ->
        match p with
        | Some (Set p1), Some (Set p2) ->
          size_with_set size1 p1;
          size_with_set size2 p2;
          Set (p1 @ p2)
        | Some (Set p1), None ->
          size_with_set size1 p1;
          Set (p1 @ value y)
        | None, Some (Set p2) ->
          size_with_set size2 p2;
          Set (value x @ p2 )
        | Some (Patch p1), Some (Patch p2) ->
          let p1 = update_patch1 p1 in
          let p2 = update_patch2 p2 in
          Patch (p1 @ p2)
        | Some (Patch p1), None -> Patch (update_patch1 p1)
        | None, Some (Patch p2) -> Patch (update_patch2 p2)
        | Some (Patch p1), Some (Set s2) ->
          let s1 = value x in
          size_with_set size1 s1;
          size_with_set size2 s2;
          Set(s1 @ s2)
        | Some (Set s1), Some (Patch p2) ->
          size_with_set size1 s1;
          let s2 = value y in
          size_with_set size2 s2;
          Set(s1 @ s2)
        | None,None -> assert false
      ) tuple_ev in
    make_from (v1 @ v2) merged_ev

  let inverse : 'a . 'a p -> 'a p = function
    | I (i,x) -> I(-i-1, x)
    | U (i,x) -> U(-i-1, x)
    | R i -> R (-i-1)
    | X (i,j) -> X (-i-1,-j)

  let rev t =
    let e = React.E.map (function
        | Set l -> Set (List.rev l)
        | Patch p -> Patch (List.map inverse p))  (event t)
    in
    make_from (List.rev (value t)) e

  let sort eq t = `Not_implemented
    (* let e = React.E.map (function *)
    (*     | Set l -> Set (List.sort eq l) *)
    (*     | Patch p -> Patch p)  (event t) *)
    (* in *)
    (* make_from (List.sort eq (value t)) e *)

  let filter f t = `Not_implemented

end

module RMap(M : Map.S) = struct
  module Data = struct
    type 'a data = 'a M.t
    type 'a patch = [`Add of (M.key * 'a) | `Del of M.key]
    let merge p s =
      match p with
      | `Add (k,a) -> M.add k a s
      | `Del k -> M.remove k s
    let map_patch f = function
      | `Add (k,a) -> `Add (k,f a)
      | `Del k -> `Del k
    let map_data f d = M.map f d
    let empty = M.empty
  end
  include Make (Data)
end
