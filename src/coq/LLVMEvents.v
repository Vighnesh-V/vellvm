(* -------------------------------------------------------------------------- *
 *                     Vellvm - the Verified LLVM project                     *
 *                                                                            *
 *     Copyright (c) 2017 Steve Zdancewic <stevez@cis.upenn.edu>              *
 *                                                                            *
 *   This file is distributed under the terms of the GNU General Public       *
 *   License as published by the Free Software Foundation, either version     *
 *   3 of the License, or (at your option) any later version.                 *
 ---------------------------------------------------------------------------- *)

From Coq Require Import
     ZArith
     List
     String
     Setoid
     Morphisms
     Omega
     Classes.RelationClasses.

From ExtLib Require Import
     Core.RelDec
     Programming.Eqv
     Structures.Monads.

From ITree Require Import
     ITree
     Events.Exception.

From Vellvm Require Import
     Util
     LLVMAst
     MemoryAddress
     DynamicTypes
     DynamicValues
     Error.

(****************************** LLVM Events *******************************)
(**
   Vellvm's semantics relies on _Interaction Trees_, a generic data-structure allowing to model
   effectful computations.
   This file defined the interface provided to the interaction trees, that is the set of
   events that a LLVM program can trigger.
   These events are then concretely interpreted as a succession of handler, as defined in the
   _Handlers_ folder.
   The possible events are:
   * Function calls [CallE]
   * Calls to intrinsics whose implementation _do not_ depends on the memory [IntrinsicE]
   * Interactions with the global environment [GlobalE]
   * Interactions with the local environment [LocalE]
   * Manipulation of the frame stack for local environments [StackE]
   * Interactions with the memory [MemoryE]
   * Concretization of a under-defined value [PickE]
   * Undefined behaviour [UBE]
   * Failure [FailureE]
   * Debugging messages [DebugE]
*)

Set Implicit Arguments.
Set Contextual Implicit.

(* Events tracking the nature of the previous block visited.
   Used to denote phi-nodes.
 *)
Variant JmpE: Type -> Type :=
| GoTo (l: block_id): JmpE unit
| ComeFrom: JmpE block_id.

 (* Interactions with global variables for the LLVM IR *)
 (* YZ: Globals are read-only, except for the initialization. We may want to reflect this in the events. *)
  Variant GlobalE (k v:Type) : Type -> Type :=
  | GlobalWrite (id: k) (dv: v): GlobalE k v unit
  | GlobalRead  (id: k): GlobalE k v v.

  (* Interactions with local variables for the LLVM IR *)
  Variant LocalE (k v:Type) : Type -> Type :=
  | LocalWrite (id: k) (dv: v): LocalE k v unit
  | LocalRead  (id: k): LocalE k v v.

  Variant StackE (k v:Type) : Type -> Type :=
  | StackPush (args: list (k * v)) : StackE k v unit (* Pushes a fresh environment during a call *)
  | StackPop : StackE k v unit. (* Pops it back during a ret *)

  (* Undefined behaviour carries a string. *)
  Variant UBE : Type -> Type :=
  | ThrowUB : string -> UBE void.

  (** Since the output type of [ThrowUB] is [void], we can make it an action
    with any return type. *)
  Definition raiseUB {E : Type -> Type} `{UBE -< E} {X}
             (e : string)
    : itree E X
    := vis (ThrowUB e) (fun v : void => match v with end).

  (* Debug is identical to the "Trace" effect from the itrees library,
   but debug is probably a less confusing name for us. *)
  Variant DebugE : Type -> Type :=
  | Debug : string -> DebugE unit.
  (* Utilities to conveniently trigger debug events *)
  Definition debug {E} `{DebugE -< E} (msg : string) : itree E unit :=
    trigger (Debug msg).

  Definition FailureE := exceptE string.

  Definition raise {E} {A} `{FailureE -< E} (msg : string) : itree E A :=
    throw msg.

  Definition lift_err {A B} {E} `{FailureE -< E} (f : A -> itree E B) (m:err A) : itree E B :=
    match m with
    | inl x => throw x
    | inr x => f x
    end.

  Definition lift_pure_err {A} {E} `{FailureE -< E} (m:err A) : itree E A :=
    lift_err ret m.

  Definition lift_undef_or_err {A B} {E} `{FailureE -< E} `{UBE -< E} (f : A -> itree E B) (m:undef_or_err A) : itree E B :=
    match m with
    | mkEitherT m =>
      match m with
      | inl x => raiseUB x
      | inr (inl x) => throw x
      | inr (inr x) => f x
      end
    end.

(* SAZ: TODO: decouple these definitions from the instance of DVALUE and DTYP by using polymorphism
   not functors. *)
Module Type LLVM_INTERACTIONS (ADDR : MemoryAddress.ADDRESS).

  Global Instance eq_dec_addr : RelDec (@eq ADDR.addr) := RelDec_from_dec _ ADDR.eq_dec.
  Global Instance Eqv_addr : Eqv ADDR.addr := (@eq ADDR.addr).

  (* The set of dynamic types manipulated by an LLVM program.  Mostly
   isomorphic to LLVMAst.typ but
     - pointers have no further detail
     - identified types are not allowed
   Questions:
     - What to do with Opaque?
   *)

  Module DV := DynamicValues.DVALUE(ADDR).
  Export DV.

  (* Generic calls, refined by [denote_mcfg] *)
  Variant CallE : Type -> Type :=
    (* TODO: not sure about uvalue for f here *)
  | Call        : forall (t:dtyp) (f:uvalue) (args:list uvalue), CallE uvalue.

  Variant ExternalCallE : Type -> Type :=
    (* TODO: is f a dvalue or a uvalue? *)
  | ExternalCall        : forall (t:dtyp) (f:uvalue) (args:list dvalue), ExternalCallE dvalue.

  (* Call to an intrinsic whose implementation do not rely on the implementation of the memory model *)
  Variant IntrinsicE : Type -> Type :=
  | Intrinsic : forall (t:dtyp) (f:string) (args:list dvalue), IntrinsicE dvalue.

  (* Interactions with the memory for the LLVM IR *)
  Variant MemoryE : Type -> Type :=
  | MemPush : MemoryE unit
  | MemPop  : MemoryE unit
  | Alloca  : forall (t:dtyp),                               (MemoryE dvalue)
  | Load    : forall (t:dtyp)   (a:dvalue),                  (MemoryE uvalue)
  | Store   : forall (a:dvalue) (v:dvalue),                  (MemoryE unit)
  | GEP     : forall (t:dtyp)   (v:dvalue) (vs:list dvalue), (MemoryE dvalue)
  | ItoP    : forall (i:dvalue),                             (MemoryE dvalue)
  | PtoI    : forall (t:dtyp) (a:dvalue),                    (MemoryE dvalue)
  (* | MemoryIntrinsic : forall (t:dtyp) (f:function_id) (args:list dvalue), MemoryE dvalue *)
  .

  (* An event resolving the non-determinism induced by undef.
   The argument _P_ is intended to be a predicate over the set
   of dvalues _u_ can take such that if it is not satisfied, the
   only possible execution is to raise _UB_.
   *)
  Variant PickE : Type -> Type :=
  | pick (u:uvalue) (P : Prop) : PickE dvalue.

  Definition unique_prop (uv : uvalue) : Prop
    := exists x, forall dv, concretize uv dv -> dv = x.

  Definition pickAll (p : uvalue -> PickE dvalue) := map_monad (fun uv => trigger (p uv)).

  (* The signatures for computations that we will use during the successive stages of the interpretation of LLVM programs *)
  (* YZ TODO: The events and handlers are parameterized by the types of key and value.
     It's weird for it to be the case if the events are concretely instantiated right here.
     At least TODO: remove these prefixes that are inconsistent with other names.
   *)
  Definition LLVMGEnvE := (GlobalE raw_id dvalue).
  Definition LLVMEnvE := (LocalE raw_id uvalue).
  Definition LLVMStackE := (StackE raw_id uvalue).

  Definition conv_E := MemoryE +' PickE +' UBE +' DebugE +' FailureE.
  Definition lookup_E := LLVMGEnvE +' LLVMEnvE.
  Definition exp_E := LLVMGEnvE +' LLVMEnvE +' MemoryE +' PickE +' UBE +' DebugE +' FailureE.

  Definition lookup_E_to_exp_E : lookup_E ~> exp_E :=
    fun T e =>
      match e with
      | inl1 e => inl1 e
      | inr1 e => inr1 (inl1 e)
      end.

  Definition conv_E_to_exp_E : conv_E ~> exp_E :=
    fun T e => inr1 (inr1 e).

  Definition instr_E := CallE +' IntrinsicE +' JmpE +' exp_E.
  Definition exp_E_to_instr_E : exp_E ~> instr_E:=
    fun T e => inr1 (inr1 (inr1 e)).

  (* Core effects. *)
  Definition L0' := CallE +' ExternalCallE +' IntrinsicE +' JmpE +' LLVMGEnvE +' (LLVMEnvE +' LLVMStackE) +' MemoryE +' PickE +' UBE +' DebugE +' FailureE.

  Definition instr_E_to_L0' : instr_E ~> L0' :=
    fun T e =>
      match e with
      | inl1 e => inl1 e
      | inr1 (inl1 e) => inr1 (inr1 (inl1 e))
      | inr1 (inr1 (inl1 e)) => inr1 (inr1 (inr1 (inl1 e)))
      | inr1 (inr1 (inr1 (inl1 e))) => inr1 (inr1 (inr1 (inr1 (inl1 e))))
      | inr1 (inr1 (inr1 (inr1 (inl1 e)))) => inr1 (inr1 (inr1 (inr1 (inr1 (inl1 (inl1 e))))))
      | inr1 (inr1 (inr1 (inr1 (inr1 e)))) => inr1 (inr1 (inr1 (inr1 (inr1 (inr1 e)))))
      end.
  
  Definition _exp_E_to_L0' : exp_E ~> L0' :=
    fun T e => instr_E_to_L0' (exp_E_to_instr_E e).

  Definition _failure_UB_to_ExpE : (FailureE +' UBE) ~> exp_E :=
    fun T e =>
      match e with
      | inl1 x => inr1 (inr1 (inr1 (inr1 (inr1 (inr1 x)))))
      | inr1 x => inr1 (inr1 (inr1 (inr1 (inl1 x))))
      end.

  Definition L0 := ExternalCallE +' IntrinsicE +' JmpE +' LLVMGEnvE +' (LLVMEnvE +' LLVMStackE) +' MemoryE +' PickE +' UBE +' DebugE +' FailureE.

  (* exp_E = LLVMGEnvE +' LLVMEnvE +' MemoryE +' PickE +' UBE +' DebugE +' FailureE *)
  (* L0 = ExternalCallE +' IntrinsicE +' LLVMGEnvE +' (LLVMEnvE +' LLVMStackE) +' MemoryE +' PickE +' UBE +' DebugE +' FailureE *)

  Definition _exp_E_to_L0 : exp_E ~> L0 :=
    fun T e =>
      match e with
      | inl1 e => inr1 (inr1 (inr1 (inl1 e)))
      | inr1 (inl1 e) => inr1 (inr1 (inr1 (inr1 (inl1 (inl1 e)))))
      | inr1 (inr1 e) => inr1 (inr1 (inr1 (inr1 (inr1 e))))
      end.

  (* Definition _L0_to_L0' : L0 ~> L0' := *)
  (*   fun _ e => *)
  (*     match e with *)
  (*     | inl1 e => inl1 (inr1 e) *)
  (*     | inr1 e => (inr1 e) *)
  (*     end. *)

  (* For multiple CFG, after interpreting [GlobalE] *)
  Definition L1 := ExternalCallE +' IntrinsicE +' (LLVMEnvE +' LLVMStackE) +' MemoryE +' PickE +' UBE +' DebugE +' FailureE.

  (* For multiple CFG, after interpreting [LocalE] *)
  Definition L2 := ExternalCallE +' IntrinsicE +' MemoryE +' PickE +' UBE +' DebugE +' FailureE.

  (* For multiple CFG, after interpreting [LocalE] and [MemoryE] and [IntrinsicE] that are memory intrinsics *)
  Definition L3 := ExternalCallE +' PickE +' UBE +' DebugE +' FailureE.

  (* For multiple CFG, after interpreting [LocalE] and [MemoryE] and [IntrinsicE] that are memory intrinsics and [PickE]*)
  Definition L4 := ExternalCallE +' UBE +' DebugE +' FailureE.

  Definition L5 := ExternalCallE +' DebugE +' FailureE.

  Hint Unfold L0 L0' L1 L2 L3 L4 L5 : core.

  Definition _failure_UB_to_L4 : (FailureE +' UBE) ~> L4:=
    fun T e =>
      match e with
      | inl1 x => inr1 (inr1 (inr1 x))
      | inr1 x => inr1 (inl1 x)
      end.

End LLVM_INTERACTIONS.

Module Make(ADDR : MemoryAddress.ADDRESS) <: LLVM_INTERACTIONS(ADDR).
Include LLVM_INTERACTIONS(ADDR).
End Make.
