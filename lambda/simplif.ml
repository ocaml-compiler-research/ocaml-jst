(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*             Xavier Leroy, projet Cristal, INRIA Rocquencourt           *)
(*                                                                        *)
(*   Copyright 1996 Institut National de Recherche en Informatique et     *)
(*     en Automatique.                                                    *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

(* Elimination of useless Llet(Alias) bindings.
   Also transform let-bound references into variables. *)

open Asttypes
open Lambda
open Debuginfo.Scoped_location

(* To transform let-bound references into variables *)

exception Real_reference

let rec eliminate_ref id = function
    Lvar v as lam ->
      if Ident.same v id then raise Real_reference else lam
  | Lconst _ as lam -> lam
  | Lapply ap ->
      Lapply{ap with ap_func = eliminate_ref id ap.ap_func;
                     ap_args = List.map (eliminate_ref id) ap.ap_args}
  | Lfunction _ as lam ->
      if Ident.Set.mem id (free_variables lam)
      then raise Real_reference
      else lam
  | Llet(str, kind, v, e1, e2) ->
      Llet(str, kind, v, eliminate_ref id e1, eliminate_ref id e2)
  | Lletrec(idel, e2) ->
      Lletrec(List.map (fun (v, e) -> (v, eliminate_ref id e)) idel,
              eliminate_ref id e2)
  | Lprim(Pfield (0, _sem), [Lvar v], _) when Ident.same v id ->
      Lvar id
  | Lprim(Psetfield(0, _, _), [Lvar v; e], _)
    when Ident.same v id ->
      Lassign(id, eliminate_ref id e)
  | Lprim(Poffsetref delta, [Lvar v], loc) when Ident.same v id ->
      Lassign(id, Lprim(Poffsetint delta, [Lvar id], loc))
  | Lprim(p, el, loc) ->
      Lprim(p, List.map (eliminate_ref id) el, loc)
  | Lswitch(e, sw, loc) ->
      Lswitch(eliminate_ref id e,
        {sw_numconsts = sw.sw_numconsts;
         sw_consts =
            List.map (fun (n, e) -> (n, eliminate_ref id e)) sw.sw_consts;
         sw_numblocks = sw.sw_numblocks;
         sw_blocks =
            List.map (fun (n, e) -> (n, eliminate_ref id e)) sw.sw_blocks;
         sw_failaction =
            Option.map (eliminate_ref id) sw.sw_failaction; },
        loc)
  | Lstringswitch(e, sw, default, loc) ->
      Lstringswitch
        (eliminate_ref id e,
         List.map (fun (s, e) -> (s, eliminate_ref id e)) sw,
         Option.map (eliminate_ref id) default, loc)
  | Lstaticraise (i,args) ->
      Lstaticraise (i,List.map (eliminate_ref id) args)
  | Lstaticcatch(e1, i, e2) ->
      Lstaticcatch(eliminate_ref id e1, i, eliminate_ref id e2)
  | Ltrywith(e1, v, e2) ->
      Ltrywith(eliminate_ref id e1, v, eliminate_ref id e2)
  | Lifthenelse(e1, e2, e3) ->
      Lifthenelse(eliminate_ref id e1,
                  eliminate_ref id e2,
                  eliminate_ref id e3)
  | Lsequence(e1, e2) ->
      Lsequence(eliminate_ref id e1, eliminate_ref id e2)
  | Lwhile(e1, e2) ->
      Lwhile(eliminate_ref id e1, eliminate_ref id e2)
  | Lfor(v, e1, e2, dir, e3) ->
      Lfor(v, eliminate_ref id e1, eliminate_ref id e2,
           dir, eliminate_ref id e3)
  | Lassign(v, e) ->
      Lassign(v, eliminate_ref id e)
  | Lsend(k, m, o, el, pos, mode, loc) ->
      Lsend(k, eliminate_ref id m, eliminate_ref id o,
            List.map (eliminate_ref id) el, pos, mode, loc)
  | Levent(l, ev) ->
      Levent(eliminate_ref id l, ev)
  | Lifused(v, e) ->
      Lifused(v, eliminate_ref id e)
  | Lregion e ->
      Lregion(eliminate_ref id e)

(* Simplification of exits *)

type exit = {
  mutable count: int;
  mutable max_depth: int;
}

let simplify_exits lam =

  (* Count occurrences of (exit n ...) statements *)
  let exits = Hashtbl.create 17 in

  let try_depth = ref 0 in

  let get_exit i =
    try Hashtbl.find exits i
    with Not_found -> {count = 0; max_depth = 0}

  and incr_exit i nb d =
    match Hashtbl.find_opt exits i with
    | Some r ->
        r.count <- r.count + nb;
        r.max_depth <- max r.max_depth d
    | None ->
        let r = {count = nb; max_depth = d} in
        Hashtbl.add exits i r
  in

  let rec count = function
  | (Lvar _| Lconst _) -> ()
  | Lapply ap -> count ap.ap_func; List.iter count ap.ap_args
  | Lfunction {body} -> count body
  | Llet(_str, _kind, _v, l1, l2) ->
      count l2; count l1
  | Lletrec(bindings, body) ->
      List.iter (fun (_v, l) -> count l) bindings;
      count body
  | Lprim(_p, ll, _) -> List.iter count ll
  | Lswitch(l, sw, _loc) ->
      count_default sw ;
      count l;
      List.iter (fun (_, l) -> count l) sw.sw_consts;
      List.iter (fun (_, l) -> count l) sw.sw_blocks
  | Lstringswitch(l, sw, d, _) ->
      count l;
      List.iter (fun (_, l) -> count l) sw;
      begin match  d with
      | None -> ()
      | Some d -> match sw with
        | []|[_] -> count d
        | _ -> count d; count d (* default will get replicated *)
      end
  | Lstaticraise (i,ls) -> incr_exit i 1 !try_depth; List.iter count ls
  | Lstaticcatch (l1,(i,[]),Lstaticraise (j,[])) ->
      (* i will be replaced by j in l1, so each occurrence of i in l1
         increases j's ref count *)
      count l1 ;
      let ic = get_exit i in
      incr_exit j ic.count (max !try_depth ic.max_depth)
  | Lstaticcatch(l1, (i,_), l2) ->
      count l1;
      (* If l1 does not contain (exit i),
         l2 will be removed, so don't count its exits *)
      if (get_exit i).count > 0 then
        count l2
  | Ltrywith(l1, _v, l2) -> incr try_depth; count l1; decr try_depth; count l2
  | Lifthenelse(l1, l2, l3) -> count l1; count l2; count l3
  | Lsequence(l1, l2) -> count l1; count l2
  | Lwhile(l1, l2) -> count l1; count l2
  | Lfor(_, l1, l2, _dir, l3) -> count l1; count l2; count l3
  | Lassign(_v, l) -> count l
  | Lsend(_k, m, o, ll, _, _, _) -> List.iter count (m::o::ll)
  | Levent(l, _) -> count l
  | Lifused(_v, l) -> count l
  | Lregion l -> count l

  and count_default sw = match sw.sw_failaction with
  | None -> ()
  | Some al ->
      let nconsts = List.length sw.sw_consts
      and nblocks = List.length sw.sw_blocks in
      if
        nconsts < sw.sw_numconsts && nblocks < sw.sw_numblocks
      then begin (* default action will occur twice in native code *)
        count al ; count al
      end else begin (* default action will occur once *)
        assert (nconsts < sw.sw_numconsts || nblocks < sw.sw_numblocks) ;
        count al
      end
  in
  count lam;
  assert(!try_depth = 0);

  (*
     Second pass simplify  ``catch body with (i ...) handler''
      - if (exit i ...) does not occur in body, suppress catch
      - if (exit i ...) occurs exactly once in body,
        substitute it with handler
      - If handler is a single variable, replace (exit i ..) with it
   Note:
    In ``catch body with (i x1 .. xn) handler''
     Substituted expression is
      let y1 = x1 and ... yn = xn in
      handler[x1 <- y1 ; ... ; xn <- yn]
     For the sake of preserving the uniqueness  of bound variables.
     (No alpha conversion of ``handler'' is presently needed, since
     substitution of several ``(exit i ...)''
     occurs only when ``handler'' is a variable.)
  *)

  let subst = Hashtbl.create 17 in

  let rec simplif = function
  | (Lvar _|Lconst _) as l -> l
  | Lapply ap ->
      Lapply{ap with ap_func = simplif ap.ap_func;
                     ap_args = List.map simplif ap.ap_args}
  | Lfunction{kind; params; return; body = l; attr; loc; mode; region} ->
     Lfunction{kind; params; return; body=simplif l; attr; loc; mode; region}
  | Llet(str, kind, v, l1, l2) -> Llet(str, kind, v, simplif l1, simplif l2)
  | Lletrec(bindings, body) ->
      Lletrec(List.map (fun (v, l) -> (v, simplif l)) bindings, simplif body)
  | Lprim(p, ll, loc) -> begin
    let ll = List.map simplif ll in
    match p, ll with
        (* Simplify %revapply, for n-ary functions with n > 1 *)
      | Prevapply Rc_normal, [x; Lapply ap]
      | Prevapply Rc_normal, [x; Levent (Lapply ap,_)] ->
          Lapply {ap with ap_args = ap.ap_args @ [x]; ap_loc = loc;
                          ap_region_close = Rc_normal}
      | Prevapply pos, [x; f] ->
          Lapply {
            ap_loc=loc;
            ap_func=f;
            ap_args=[x];
            ap_region_close=pos;
            ap_mode=Alloc_heap;
            ap_tailcall=Default_tailcall;
            ap_inlined=Default_inlined;
            ap_specialised=Default_specialise;
            ap_probe=None;
          }
        (* Simplify %apply, for n-ary functions with n > 1 *)
      | Pdirapply Rc_normal, [Lapply ap; x]
      | Pdirapply Rc_normal, [Levent (Lapply ap,_); x] ->
          Lapply {ap with ap_args = ap.ap_args @ [x];
                          ap_loc = loc; ap_region_close=Rc_normal}
      | Pdirapply pos, [f; x] ->
          Lapply {
            ap_loc=loc;
            ap_func=f;
            ap_args=[x];
            ap_region_close=pos;
            ap_mode=Alloc_heap;
            ap_tailcall=Default_tailcall;
            ap_inlined=Default_inlined;
            ap_specialised=Default_specialise;
            ap_probe=None;
          }
        (* Simplify %identity *)
      | Pidentity, [e] -> e

        (* Simplify Obj.with_tag *)
      | Pccall { Primitive.prim_name = "caml_obj_with_tag"; _ },
        [Lconst (Const_base (Const_int tag));
         Lprim (Pmakeblock (_, mut, shape, mode), fields, loc)] ->
         Lprim (Pmakeblock(tag, mut, shape, mode), fields, loc)
      | Pccall { Primitive.prim_name = "caml_obj_with_tag"; _ },
        [Lconst (Const_base (Const_int tag));
         Lconst (Const_block (_, fields))] ->
         Lconst (Const_block (tag, fields))

      | _ -> Lprim(p, ll, loc)
     end
  | Lswitch(l, sw, loc) ->
      let new_l = simplif l
      and new_consts =  List.map (fun (n, e) -> (n, simplif e)) sw.sw_consts
      and new_blocks =  List.map (fun (n, e) -> (n, simplif e)) sw.sw_blocks
      and new_fail = Option.map simplif sw.sw_failaction in
      Lswitch
        (new_l,
         {sw with sw_consts = new_consts ; sw_blocks = new_blocks;
                  sw_failaction = new_fail},
         loc)
  | Lstringswitch(l,sw,d,loc) ->
      Lstringswitch
        (simplif l,List.map (fun (s,l) -> s,simplif l) sw,
         Option.map simplif d,loc)
  | Lstaticraise (i,[]) as l ->
      begin try
        let _,handler =  Hashtbl.find subst i in
        handler
      with
      | Not_found -> l
      end
  | Lstaticraise (i,ls) ->
      let ls = List.map simplif ls in
      begin try
        let xs,handler =  Hashtbl.find subst i in
        let ys = List.map (fun (x, k) -> Ident.rename x, k) xs in
        let env =
          List.fold_right2
            (fun (x, _) (y, _) env -> Ident.Map.add x y env)
            xs ys Ident.Map.empty
        in
        List.fold_right2
          (fun (y, kind) l r -> Llet (Strict, kind, y, l, r))
          ys ls (Lambda.rename env handler)
      with
      | Not_found -> Lstaticraise (i,ls)
      end
  | Lstaticcatch (l1,(i,[]),(Lstaticraise (_j,[]) as l2)) ->
      Hashtbl.add subst i ([],simplif l2) ;
      simplif l1
  | Lstaticcatch (l1,(i,xs),l2) ->
      let {count; max_depth} = get_exit i in
      if count = 0 then
        (* Discard staticcatch: not matching exit *)
        simplif l1
      else if count = 1 && max_depth <= !try_depth then begin
        (* Inline handler if there is a single occurrence and it is not
           nested within an inner try..with *)
        assert(max_depth = !try_depth);
        Hashtbl.add subst i (xs,simplif l2);
        simplif l1
      end else
        Lstaticcatch (simplif l1, (i,xs), simplif l2)
  | Ltrywith(l1, v, l2) ->
      incr try_depth;
      let l1 = simplif l1 in
      decr try_depth;
      Ltrywith(l1, v, simplif l2)
  | Lifthenelse(l1, l2, l3) -> Lifthenelse(simplif l1, simplif l2, simplif l3)
  | Lsequence(l1, l2) -> Lsequence(simplif l1, simplif l2)
  | Lwhile(l1, l2) -> Lwhile(simplif l1, simplif l2)
  | Lfor(v, l1, l2, dir, l3) ->
      Lfor(v, simplif l1, simplif l2, dir, simplif l3)
  | Lassign(v, l) -> Lassign(v, simplif l)
  | Lsend(k, m, o, ll, pos, mode, loc) ->
      Lsend(k, simplif m, simplif o, List.map simplif ll, pos, mode, loc)
  | Levent(l, ev) -> Levent(simplif l, ev)
  | Lifused(v, l) -> Lifused (v,simplif l)
  | Lregion l -> Lregion (simplif l)
  in
  simplif lam

(* Compile-time beta-reduction of functions immediately applied:
      Lapply(Lfunction(Curried, params, body), args, loc) ->
        let paramN = argN in ... let param1 = arg1 in body
      Lapply(Lfunction(Tupled, params, body), [Lprim(Pmakeblock(args))], loc) ->
        let paramN = argN in ... let param1 = arg1 in body
   Assumes |args| = |params|.
*)

let exact_application {kind; params; _} args =
  match kind with
  | Curried _ ->
      if List.length params <> List.length args
      then None
      else Some args
  | Tupled ->
      begin match args with
      | [Lprim(Pmakeblock _, tupled_args, _)] ->
          if List.length params <> List.length tupled_args
          then None
          else Some tupled_args
      | [Lconst(Const_block (_, const_args))] ->
          if List.length params <> List.length const_args
          then None
          else Some (List.map (fun cst -> Lconst cst) const_args)
      | _ -> None
      end

let beta_reduce params body args =
  List.fold_left2 (fun l (param, kind) arg -> Llet(Strict, kind, param, arg, l))
                  body params args

(* Simplification of lets *)

let simplify_lets lam =

  (* Disable optimisations for bytecode compilation with -g flag *)
  let optimize = !Clflags.native_code || not !Clflags.debug in

  (* First pass: count the occurrences of all let-bound identifiers *)

  let occ = (Hashtbl.create 83: (Ident.t, int ref) Hashtbl.t) in
  (* The global table [occ] associates to each let-bound identifier
     the number of its uses (as a reference):
     - 0 if never used
     - 1 if used exactly once in and not under a lambda or within a loop
     - > 1 if used several times or under a lambda or within a loop.
     The local table [bv] associates to each locally-let-bound variable
     its reference count, as above.  [bv] is enriched at let bindings
     but emptied when crossing lambdas and loops. *)

  (* Current use count of a variable. *)
  let count_var v =
    try
      !(Hashtbl.find occ v)
    with Not_found ->
      0

  (* Entering a [let].  Returns updated [bv]. *)
  and bind_var bv v =
    let r = ref 0 in
    Hashtbl.add occ v r;
    Ident.Map.add v r bv

  (* Record a use of a variable *)
  and use_var bv v n =
    try
      let r = Ident.Map.find v bv in r := !r + n
    with Not_found ->
      (* v is not locally bound, therefore this is a use under a lambda
         or within a loop.  Increase use count by 2 -- enough so
         that single-use optimizations will not apply. *)
    try
      let r = Hashtbl.find occ v in r := !r + 2
    with Not_found ->
      (* Not a let-bound variable, ignore *)
      () in

  let rec count bv = function
  | Lconst _ -> ()
  | Lvar v ->
      use_var bv v 1
  | Lapply{ap_func = ll; ap_args = args} ->
      let no_opt () = count bv ll; List.iter (count bv) args in
      begin match ll with
      | Lfunction lf when optimize ->
          begin match exact_application lf args with
          | None -> no_opt ()
          | Some exact_args ->
              count bv (beta_reduce lf.params lf.body exact_args)
          end
      | _ -> no_opt ()
      end
  | Lfunction {body} ->
      count Ident.Map.empty body
  | Llet(_str, _k, v, Lvar w, l2) when optimize ->
      (* v will be replaced by w in l2, so each occurrence of v in l2
         increases w's refcount *)
      count (bind_var bv v) l2;
      use_var bv w (count_var v)
  | Llet(str, _kind, v, l1, l2) ->
      count (bind_var bv v) l2;
      (* If v is unused, l1 will be removed, so don't count its variables *)
      if str = Strict || count_var v > 0 then count bv l1
  | Lletrec(bindings, body) ->
      List.iter (fun (_v, l) -> count bv l) bindings;
      count bv body
  | Lprim(_p, ll, _) -> List.iter (count bv) ll
  | Lswitch(l, sw, _loc) ->
      count_default bv sw ;
      count bv l;
      List.iter (fun (_, l) -> count bv l) sw.sw_consts;
      List.iter (fun (_, l) -> count bv l) sw.sw_blocks
  | Lstringswitch(l, sw, d, _) ->
      count bv l ;
      List.iter (fun (_, l) -> count bv l) sw ;
      begin match d with
      | Some d ->
          begin match sw with
          | []|[_] -> count bv d
          | _ -> count bv d ; count bv d
          end
      | None -> ()
      end
  | Lstaticraise (_i,ls) -> List.iter (count bv) ls
  | Lstaticcatch(l1, _, l2) -> count bv l1; count bv l2
  | Ltrywith(l1, _v, l2) -> count bv l1; count bv l2
  | Lifthenelse(l1, l2, l3) -> count bv l1; count bv l2; count bv l3
  | Lsequence(l1, l2) -> count bv l1; count bv l2
  | Lwhile(l1, l2) -> count Ident.Map.empty l1; count Ident.Map.empty l2
  | Lfor(_, l1, l2, _dir, l3) ->
      count bv l1; count bv l2; count Ident.Map.empty l3
  | Lassign(_v, l) ->
      (* Lalias-bound variables are never assigned, so don't increase
         v's refcount *)
      count bv l
  | Lsend(_, m, o, ll, _, _, _) -> List.iter (count bv) (m::o::ll)
  | Levent(l, _) -> count bv l
  | Lifused(v, l) ->
      if count_var v > 0 then count bv l
  | Lregion l ->
      count bv l

  and count_default bv sw = match sw.sw_failaction with
  | None -> ()
  | Some al ->
      let nconsts = List.length sw.sw_consts
      and nblocks = List.length sw.sw_blocks in
      if
        nconsts < sw.sw_numconsts && nblocks < sw.sw_numblocks
      then begin (* default action will occur twice in native code *)
        count bv al ; count bv al
      end else begin (* default action will occur once *)
        assert (nconsts < sw.sw_numconsts || nblocks < sw.sw_numblocks) ;
        count bv al
      end
  in
  count Ident.Map.empty lam;

  (* Second pass: remove Lalias bindings of unused variables,
     and substitute the bindings of variables used exactly once. *)

  let subst = Hashtbl.create 83 in

(* This (small)  optimisation is always legal, it may uncover some
   tail call later on. *)

  let mklet str kind v e1 e2  = match e2 with
  | Lvar w when optimize && Ident.same v w -> e1
  | _ -> Llet (str, kind,v,e1,e2) in


  let rec simplif = function
    Lvar v as l ->
      begin try
        Hashtbl.find subst v
      with Not_found ->
        l
      end
  | Lconst _ as l -> l
  | Lapply ({ap_func = ll; ap_args = args} as ap) ->
      let no_opt () =
        Lapply {ap with ap_func = simplif ap.ap_func;
                        ap_args = List.map simplif ap.ap_args} in
      begin match ll with
      | Lfunction lf when optimize ->
          begin match exact_application lf args with
          | None -> no_opt ()
          | Some exact_args ->
              simplif (beta_reduce lf.params lf.body exact_args)
          end
      | _ -> no_opt ()
      end
  | Lfunction({kind=Curried {nlocal=0}; params; return=_return1; body = l;
               attr=_; loc=_; mode; region=true} as fn) ->
      begin match simplif l with
        Lfunction{kind=Curried _ as kind; params=params'; return=return2;
                  body; attr; loc; mode=inner_mode; region}
        when optimize &&
             List.length params + List.length params' <= Lambda.max_arity() ->
          (* The returned function's mode should match the outer return mode *)
          assert (inner_mode = Alloc_heap);
          (* The return type is the type of the value returned after
             applying all the parameters to the function. The return
             type of the merged function taking [params @ params'] as
             parameters is the type returned after applying [params']. *)
          let return = return2 in
          Lfunction{kind; params = params @ params'; return;
                    body; attr; loc; mode; region}
      | body ->
          Lfunction{fn with body}
      end
  | Lfunction fn -> Lfunction {fn with body = simplif fn.body}
  | Llet(_str, _k, v, Lvar w, l2) when optimize ->
      Hashtbl.add subst v (simplif (Lvar w));
      simplif l2
  | Llet(Strict, kind, v,
         Lprim(Pmakeblock(0, Mutable, kind_ref, _mode) as prim, [linit], loc),
         lbody)
    when optimize ->
      let slinit = simplif linit in
      let slbody = simplif lbody in
      begin try
        let kind = match kind_ref with
          | None -> Pgenval
          | Some [field_kind] -> field_kind
          | Some _ -> assert false
        in
        mklet Variable kind v slinit (eliminate_ref v slbody)
      with Real_reference ->
        mklet Strict kind v (Lprim(prim, [slinit], loc)) slbody
      end
  | Llet(Alias, kind, v, l1, l2) ->
      begin match count_var v with
        0 -> simplif l2
      | 1 when optimize -> Hashtbl.add subst v (simplif l1); simplif l2
      | _ -> Llet(Alias, kind, v, simplif l1, simplif l2)
      end
  | Llet(StrictOpt, kind, v, l1, l2) ->
      begin match count_var v with
        0 -> simplif l2
      | _ -> mklet StrictOpt kind v (simplif l1) (simplif l2)
      end
  | Llet(str, kind, v, l1, l2) -> mklet str kind v (simplif l1) (simplif l2)
  | Lletrec(bindings, body) ->
      Lletrec(List.map (fun (v, l) -> (v, simplif l)) bindings, simplif body)
  | Lprim(p, ll, loc) -> Lprim(p, List.map simplif ll, loc)
  | Lswitch(l, sw, loc) ->
      let new_l = simplif l
      and new_consts =  List.map (fun (n, e) -> (n, simplif e)) sw.sw_consts
      and new_blocks =  List.map (fun (n, e) -> (n, simplif e)) sw.sw_blocks
      and new_fail = Option.map simplif sw.sw_failaction in
      Lswitch
        (new_l,
         {sw with sw_consts = new_consts ; sw_blocks = new_blocks;
                  sw_failaction = new_fail},
         loc)
  | Lstringswitch (l,sw,d,loc) ->
      Lstringswitch
        (simplif l,List.map (fun (s,l) -> s,simplif l) sw,
         Option.map simplif d,loc)
  | Lstaticraise (i,ls) ->
      Lstaticraise (i, List.map simplif ls)
  | Lstaticcatch(l1, (i,args), l2) ->
      Lstaticcatch (simplif l1, (i,args), simplif l2)
  | Ltrywith(l1, v, l2) -> Ltrywith(simplif l1, v, simplif l2)
  | Lifthenelse(l1, l2, l3) -> Lifthenelse(simplif l1, simplif l2, simplif l3)
  | Lsequence(Lifused(v, l1), l2) ->
      if count_var v > 0
      then Lsequence(simplif l1, simplif l2)
      else simplif l2
  | Lsequence(l1, l2) -> Lsequence(simplif l1, simplif l2)
  | Lwhile(l1, l2) -> Lwhile(simplif l1, simplif l2)
  | Lfor(v, l1, l2, dir, l3) ->
      Lfor(v, simplif l1, simplif l2, dir, simplif l3)
  | Lassign(v, l) -> Lassign(v, simplif l)
  | Lsend(k, m, o, ll, pos, mode, loc) ->
      Lsend(k, simplif m, simplif o, List.map simplif ll, pos, mode, loc)
  | Levent(l, ev) -> Levent(simplif l, ev)
  | Lifused(v, l) ->
      if count_var v > 0 then simplif l else lambda_unit
  | Lregion l -> Lregion (simplif l)
  in
  simplif lam

(* Tail call info in annotation files *)

let rec emit_tail_infos is_tail lambda =
  match lambda with
  | Lvar _ -> ()
  | Lconst _ -> ()
  | Lapply ap ->
      begin
        (* Note: is_tail does not take backend-specific logic into
           account (maximum number of parameters, etc.)  so it may
           over-approximate tail-callness.

           Trying to do something more fine-grained would result in
           different warnings depending on whether the native or
           bytecode compiler is used. *)
        let maybe_warn ~is_tail ~expect_tail =
          if is_tail <> expect_tail then
            Location.prerr_warning (to_location ap.ap_loc)
              (Warnings.Wrong_tailcall_expectation expect_tail) in
        match ap.ap_tailcall with
        | Default_tailcall -> ()
        | Tailcall_expectation expect_tail ->
            maybe_warn ~is_tail ~expect_tail
      end;
      emit_tail_infos false ap.ap_func;
      list_emit_tail_infos false ap.ap_args
  | Lfunction {body = lam} ->
      emit_tail_infos true lam
  | Llet (_str, _k, _, lam, body) ->
      emit_tail_infos false lam;
      emit_tail_infos is_tail body
  | Lletrec (bindings, body) ->
      List.iter (fun (_, lam) -> emit_tail_infos false lam) bindings;
      emit_tail_infos is_tail body
  | Lprim (Pidentity, [arg], _) ->
      emit_tail_infos is_tail arg
  | Lprim ((Pbytes_to_string | Pbytes_of_string), [arg], _) ->
      emit_tail_infos is_tail arg
  | Lprim (Psequand, [arg1; arg2], _)
  | Lprim (Psequor, [arg1; arg2], _) ->
      emit_tail_infos false arg1;
      emit_tail_infos is_tail arg2
  | Lprim (_, l, _) ->
      list_emit_tail_infos false l
  | Lswitch (lam, sw, _loc) ->
      emit_tail_infos false lam;
      list_emit_tail_infos_fun snd is_tail sw.sw_consts;
      list_emit_tail_infos_fun snd is_tail sw.sw_blocks;
      Option.iter  (emit_tail_infos is_tail) sw.sw_failaction
  | Lstringswitch (lam, sw, d, _) ->
      emit_tail_infos false lam;
      List.iter
        (fun (_,lam) ->  emit_tail_infos is_tail lam)
        sw ;
      Option.iter (emit_tail_infos is_tail) d
  | Lstaticraise (_, l) ->
      list_emit_tail_infos false l
  | Lstaticcatch (body, _, handler) ->
      emit_tail_infos is_tail body;
      emit_tail_infos is_tail handler
  | Ltrywith (body, _, handler) ->
      emit_tail_infos false body;
      emit_tail_infos is_tail handler
  | Lifthenelse (cond, ifso, ifno) ->
      emit_tail_infos false cond;
      emit_tail_infos is_tail ifso;
      emit_tail_infos is_tail ifno
  | Lsequence (lam1, lam2) ->
      emit_tail_infos false lam1;
      emit_tail_infos is_tail lam2
  | Lwhile (cond, body) ->
      emit_tail_infos false cond;
      emit_tail_infos false body
  | Lfor (_, low, high, _, body) ->
      emit_tail_infos false low;
      emit_tail_infos false high;
      emit_tail_infos false body
  | Lassign (_, lam) ->
      emit_tail_infos false lam
  | Lsend (_, meth, obj, args, _, _, _loc) ->
      emit_tail_infos false meth;
      emit_tail_infos false obj;
      list_emit_tail_infos false args
  | Levent (lam, _) ->
      emit_tail_infos is_tail lam
  | Lifused (_, lam) ->
      emit_tail_infos is_tail lam
  | Lregion lam ->
      emit_tail_infos is_tail lam
and list_emit_tail_infos_fun f is_tail =
  List.iter (fun x -> emit_tail_infos is_tail (f x))
and list_emit_tail_infos is_tail =
  List.iter (emit_tail_infos is_tail)

(* Split a function with default parameters into a wrapper and an
   inner function.  The wrapper fills in missing optional parameters
   with their default value and tail-calls the inner function.  The
   wrapper can then hopefully be inlined on most call sites to avoid
   the overhead associated with boxing an optional argument with a
   'Some' constructor, only to deconstruct it immediately in the
   function's body. *)

let split_default_wrapper ~id:fun_id ~kind ~params ~return ~body
      ~attr ~loc ~mode ~region:orig_region =
  let rec aux map add_region = function
    | Llet(Strict, k, id, (Lifthenelse(Lvar optparam, _, _) as def), rest) when
        (not (Clflags.is_flambda2 ()))
          && Ident.name optparam = "*opt*" && List.mem_assoc optparam params
          && not (List.mem_assoc optparam map)
      ->
        let wrapper_body, inner = aux ((optparam, id) :: map) add_region rest in
        Llet(Strict, k, id, def, wrapper_body), inner
    | Llet(Strict, k, id,
        (Lswitch(Lvar optparam,
           {sw_numconsts = 1;
            sw_consts = [_];
            sw_numblocks = 1;
            sw_blocks = [_];
            sw_failaction = None}, _dbg)
         as def), rest) when
        Clflags.is_flambda2 ()
          && Ident.name optparam = "*opt*" && List.mem_assoc optparam params
          && not (List.mem_assoc optparam map)
      ->
        let wrapper_body, inner = aux ((optparam, id) :: map) add_region rest in
        Llet(Strict, k, id, def, wrapper_body), inner
    | Lregion rest -> aux map true rest
    | _ when map = [] -> raise Exit
    | body ->
        (* Check that those *opt* identifiers don't appear in the remaining
           body. This should not appear, but let's be on the safe side. *)
        let fv = Lambda.free_variables body in
        List.iter (fun (id, _) -> if Ident.Set.mem id fv then raise Exit) map;

        let inner_id = Ident.create_local (Ident.name fun_id ^ "_inner") in
        let map_param p = try List.assoc p map with Not_found -> p in
        let args = List.map (fun (p, _) -> Lvar (map_param p)) params in
        let wrapper_body =
          Lapply {
            ap_func = Lvar inner_id;
            ap_args = args;
            ap_loc = Loc_unknown;
            ap_region_close = Rc_normal;
            ap_mode = Alloc_heap;
            ap_tailcall = Default_tailcall;
            ap_inlined = Default_inlined;
            ap_specialised = Default_specialise;
            ap_probe=None;
          }
        in
        let inner_params = List.map map_param (List.map fst params) in
        let new_ids = List.map Ident.rename inner_params in
        let subst =
          List.fold_left2 (fun s id new_id ->
            Ident.Map.add id new_id s
          ) Ident.Map.empty inner_params new_ids
        in
        let body = Lambda.rename subst body in
        let body = if add_region then Lregion body else body in
        let inner_fun =
          Lfunction { kind = Curried {nlocal=0};
            params = List.map (fun id -> id, Pgenval) new_ids;
            return; body; attr; loc; mode; region=true }
        in
        (wrapper_body, (inner_id, inner_fun))
  in
  try
    (* TODO: enable this optimisation even in the presence of local returns *)
    begin match kind with
    | Curried {nlocal} when nlocal > 0 -> raise Exit
    | Tupled when not orig_region -> raise Exit
    | _ -> assert orig_region
    end;
    let body, inner = aux [] false body in
    let attr = default_stub_attribute in
    [(fun_id, Lfunction{kind; params; return; body; attr; loc; mode;
                        region=true});
     inner]
  with Exit ->
    [(fun_id, Lfunction{kind; params; return; body; attr; loc; mode;
                        region=orig_region})]

(* Simplify local let-bound functions: if all occurrences are
   fully-applied function calls in the same "tail scope", replace the
   function by a staticcatch handler (on that scope).

   This handles as a special case functions used exactly once (in any
   scope) for a full application.
*)

type slot =
  {
    func: lfunction;
    mutable scope: lambda option;
  }

module LamTbl = Hashtbl.Make(struct
    type t = lambda
    let equal = (==)
    let hash = Hashtbl.hash
  end)

let simplify_local_functions lam =
  let slots = Hashtbl.create 16 in
  let static_id = Hashtbl.create 16 in (* function id -> static id *)
  let static = LamTbl.create 16 in (* scope -> static function on that scope *)
  (* We keep track of the current "tail scope", identified
     by the outermost lambda for which the the current lambda
     is in tail position. *)
  let current_scope = ref lam in
  let current_region_scope = ref lam in
  let check_static lf =
    if lf.attr.local = Always_local then
      Location.prerr_warning (to_location lf.loc)
        (Warnings.Inlining_impossible
           "This function cannot be compiled into a static continuation")
  in
  let enabled = function
    | {local = Always_local; _}
    | {local = Default_local;
       inline = (Never_inline | Default_inline | Available_inline); _}
      -> true
    | {local = Default_local;
       inline = (Always_inline | Unroll _); _}
    | {local = Never_local; _}
      -> false
  in
  let rec tail = function
    | Llet (_str, _kind, id, Lfunction lf, cont) when enabled lf.attr ->
        let r = {func = lf; scope = None} in
        Hashtbl.add slots id r;
        tail cont;
        begin match Hashtbl.find_opt slots id with
        | Some {scope = Some scope; _} ->
            let st = next_raise_count () in
            let sc =
              (* Do not move higher than current lambda *)
              if scope == !current_scope
              || scope == !current_region_scope then cont
              else scope
            in
            Hashtbl.add static_id id st;
            LamTbl.add static sc (st, lf);
            (* The body of the function will become an handler
               in that "scope". *)
            with_scope ~scope lf.body
        | _ ->
            check_static lf;
            (* note: if scope = None, the function is unused *)
            non_tail lf.body
        end
    | Lapply {ap_func = Lvar id; ap_args; ap_region_close; _} ->
        let curr_scope =
          match ap_region_close with
          | Rc_normal -> !current_scope
          | Rc_close_at_apply -> !current_region_scope
        in
        begin match Hashtbl.find_opt slots id with
        | Some {func; _}
          when exact_application func ap_args = None ->
            (* Wrong arity *)
            Hashtbl.remove slots id
        | Some {scope = Some scope; _} when scope != curr_scope ->
            (* Different "tail scope" *)
            Hashtbl.remove slots id
        | Some ({scope = None; _} as slot) ->
            (* First use of the function: remember the current tail scope *)
            slot.scope <- Some curr_scope
        | _ ->
            ()
        end;
        List.iter non_tail ap_args
    | Lvar id ->
        Hashtbl.remove slots id
    | Lfunction lf as lam ->
        check_static lf;
        Lambda.shallow_iter ~tail ~non_tail lam
    | Lregion lam -> region lam
    | lam ->
        Lambda.shallow_iter ~tail ~non_tail lam
  and non_tail lam =
    with_scope ~scope:lam lam
  and region lam =
    let old_tail_scope = !current_region_scope in
    current_region_scope := !current_scope;
    current_scope := lam;
    tail lam;
    current_scope := !current_region_scope;
    current_region_scope := old_tail_scope
  and with_scope ~scope lam =
    let old_scope = !current_scope in
    let old_tail_scope = !current_region_scope in
    current_scope := scope;
    current_region_scope := scope;
    tail lam;
    current_scope := old_scope;
    current_region_scope := old_tail_scope
  in
  tail lam;
  let rec rewrite lam0 =
    let lam =
      match lam0 with
      | Llet (_, _, id, _, cont) when Hashtbl.mem static_id id ->
          rewrite cont
      | Lapply {ap_func = Lvar id; ap_args; _} when Hashtbl.mem static_id id ->
         let st = Hashtbl.find static_id id in
         let slot = Hashtbl.find slots id in
         begin match exact_application slot.func ap_args with
           | None -> assert false
           | Some exact_args ->
              Lstaticraise (st, List.map rewrite exact_args)
         end
      | lam ->
          Lambda.shallow_map ~tail:rewrite ~non_tail:rewrite lam
    in
    List.fold_right
      (fun (st, lf) lam ->
         Lstaticcatch (lam, (st, lf.params), rewrite lf.body)
      )
      (LamTbl.find_all static lam0)
      lam
  in
  if LamTbl.length static = 0 then
    lam
  else
    rewrite lam

(* The entry point:
   simplification + emission of tailcall annotations, if needed. *)

let simplify_lambda lam =
  let lam =
    lam
    |> (if !Clflags.native_code || not !Clflags.debug
        then simplify_local_functions else Fun.id
       )
    |> simplify_exits
    |> simplify_lets
  in
  if !Clflags.annotations
     || Warnings.is_active (Warnings.Wrong_tailcall_expectation true)
  then emit_tail_infos true lam;
  lam
