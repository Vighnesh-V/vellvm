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
     Programming.Show
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


Set Implicit Arguments.
Set Contextual Implicit.

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

  (* Failures carry string *)
  Definition FailureE := exceptE string.

  Definition raise {E} {A} `{FailureE -< E} (msg : string) : itree E A :=
    throw msg.

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

  (****************************** LLVM Events *******************************)
  (**
   We define the denotation of an LLVM program as computation emitting several families of events.
   These events are then concretely interpreted as a succesion of handler.
   In the current approach, we fix at the top level both the universe of events, and the order in which
   they get handled. More specifically:
   * a single CFG is an [itree (CallE +' LocalE +' MemoryE +' +' IntrinsicE +' MemoryIntrinsicE +' FailureE +' DebugE)]
   * [denote_mcfg] ties the functional knot, interpreting away [CallE]
   * [Local] interprets away [LocalE]
   * [Memory] interprets away [MemoryE]
   * Both kind of intrinsics admit handlers that do not interpret away their respective universe of events, since there might remain some of them

YZ NOTE: It makes sense for [MemoryIntrinsicE] to actually live in [MemoryE]. However, that means that [Memory] cannot interpret away [MemoryE] anymore.
   *)

  (* Generic calls, refined by [denote_mcfg] *)
  Variant CallE : Type -> Type :=
  | Call        : forall (t:dtyp) (f:dvalue) (args:list dvalue), CallE dvalue.

  (* Call to an intrinsic whose implementation do not rely on the implementation of the memory model *)
  Variant IntrinsicE : Type -> Type :=
  | Intrinsic : forall (t:dtyp) (f:string) (args:list dvalue), IntrinsicE dvalue.

  (* SAZ: TODO: add Push / Pop to memory events to properly handle Alloca scoping *)
  (* Interactions with the memory for the LLVM IR *)
  Variant MemoryE : Type -> Type :=
  | Alloca : forall (t:dtyp),                             (MemoryE dvalue)
  | Load   : forall (t:dtyp) (a:dvalue),                  (MemoryE dvalue)
  | Store  : forall (a:dvalue) (v:dvalue),                (MemoryE unit)
  | GEP    : forall (t:dtyp) (v:dvalue) (vs:list dvalue), (MemoryE dvalue)
  | ItoP   : forall (i:dvalue),                           (MemoryE dvalue)
  | PtoI   : forall (a:dvalue),                           (MemoryE dvalue)
  (* | MemoryIntrinsic : forall (t:dtyp) (f:function_id) (args:list dvalue), MemoryE dvalue *)
  .

  (* Debug is identical to the "Trace" effect from the itrees library,
   but debug is probably a less confusing name for us. *)
  Variant DebugE : Type -> Type :=
  | Debug : string -> DebugE unit.


  (* The signatures for computations that we will use during the successive stages of the interpretation of LLVM programs *)

  Definition LLVM X := itree X.

  Definition LLVMGEnvE := (GlobalE raw_id dvalue).
  Definition LLVMEnvE := (LocalE raw_id dvalue).
  Definition LLVMStackE := (StackE raw_id dvalue).

  Definition conv_E := MemoryE +' DebugE +' FailureE.
  Definition lookup_E := LLVMGEnvE +' LLVMEnvE.
  Definition exp_E := LLVMGEnvE +' LLVMEnvE +' MemoryE +' DebugE +' FailureE.

  Definition lookup_E_to_exp_E : lookup_E ~> exp_E :=
    fun T e =>
      match e with
      | inl1 e => inl1 e
      | inr1 e => inr1 (inl1 e)
      end.

  Definition conv_E_to_exp_E : conv_E ~> exp_E :=
    fun T e => inr1 (inr1 e).
      
  Definition instr_E := CallE +' IntrinsicE +' exp_E.
  Definition exp_E_to_instr_E : exp_E ~> instr_E:=
    fun T e => inr1 (inr1 e).
      
  Definition fun_E := LLVMStackE +' CallE +' IntrinsicE +' exp_E.
  Definition instr_E_to_fun_E : instr_E ~> fun_E :=
    fun T e => inr1 e.

  (* Core effects - no distinction between "internal" and "external" calls. *)
  Definition _CFG := CallE +' IntrinsicE +' LLVMGEnvE +' (LLVMEnvE +' LLVMStackE) +' MemoryE +' DebugE +' FailureE.
      
  Definition _funE_to_CFG : fun_E ~> _CFG :=
    fun R e =>
      match e with
      | inl1 e' => (inr1 (inr1 (inr1 (inl1 (inr1 e')))))
      | inr1 (inl1 e') => inl1 e'
      | inr1 (inr1 (inl1 e')) => (inr1 (inl1 e'))
      | inr1 (inr1 (inr1 (inl1 e'))) => (inr1 (inr1 (inl1 e')))
      | inr1 (inr1 (inr1 (inr1 (inl1 e')))) => (inr1 (inr1 (inr1 (inl1 (inl1 e')))))
      | inr1 (inr1 (inr1 (inr1 (inr1 e)))) => (inr1 (inr1 (inr1 (inr1 e))))
      end.
  
  (* Distinction made between internal and external calls -- intermediate step in denote_mcfg.
     Note that [CallE] appears _twice_ in the [_CFG_INTERNAL] type.  The left one is 
     meant to be the "internal" call event and the right one is the "external" call event.
     The [denote_mcfg] function, which uses [mrec] to tie the recursive knot distinguishes
     the two.  It re-triggers an unknown [Call] event as an [ExternalCall] (which is just
     an injection into the right-hand side.
   *)
  Definition _CFG_INTERNAL := CallE +' _CFG.

  Definition ExternalCall t f args : _CFG_INTERNAL dvalue := (inr1 (inl1 (Call t f args))).
  
  (* This inclusion "assumes" that all call events are internal.  The 
     dispatch in denote_mcfg then interprets some of the calls directly,
     if their definitions are known, or it "externalizes" the calls
     whose definitions are not known.
   *)
  Definition _CFG_to_CFG_INTERNAL : _CFG ~> _CFG_INTERNAL :=
    fun R e =>
      match e with
      | inl1 e' => inl1 e'
      | inr1 e' => inr1 (inr1 e')
      end.

  Definition _funE_to_CFG_Internal (T:Type) e := @_CFG_to_CFG_INTERNAL T (_funE_to_CFG e).

  Definition _exp_E_to_CFG : exp_E ~> _CFG :=
    fun T e => @_funE_to_CFG T (instr_E_to_fun_E (exp_E_to_instr_E e)).
  
  (* For multiple CFG, after interpreting [GlobalE] *)
  Definition _MCFG1 := CallE +' IntrinsicE +' (LLVMEnvE +' LLVMStackE) +' MemoryE +' DebugE +' FailureE.

  (* For multiple CFG, after interpreting [LocalE] *)
  Definition _MCFG2 := CallE +' IntrinsicE +' MemoryE +' DebugE +' FailureE.

  (* For multiple CFG, after interpreting [LocalE] and [MemoryE] and [IntrinsicE] that are memory intrinsics *)
  Definition _MCFG3 := CallE +' DebugE +' FailureE.
  Hint Unfold LLVM _CFG _MCFG1 _MCFG2 _MCFG3.

  
  
  (* Utilities to conveniently trigger debug and failure events *)

  Definition lift_err {A B} {E} `{FailureE -< E} (f : A -> itree E B) (m:err A) : itree E B :=
    match m with
    | inl x => throw x
    | inr x => f x
    end.

  Definition debug {E} `{DebugE -< E} (msg : string) : itree E unit :=
    trigger (Debug msg).


End LLVM_INTERACTIONS.


Module Make(ADDR : MemoryAddress.ADDRESS) <: LLVM_INTERACTIONS(ADDR).
Include LLVM_INTERACTIONS(ADDR).
End Make.