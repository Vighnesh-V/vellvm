From ITree Require Import
     ITree
     Basics
     Eq.Eq.

From Vellvm Require Import
     Util
     UndefinedBehaviour
     DynamicValues
     MemoryAddress
     LLVMEvents
     LLVMAst
     Handlers.Handlers.

From ExtLib Require Import
     Structures.Monads
     Data.Monads.EitherMonad
     Structures.Functor.


From Coq Require Import Relations RelationClasses.

Module Make (A:MemoryAddress.ADDRESS)(LLVMEvents: LLVM_INTERACTIONS(A)).

Import LLVMEvents.
Import DV.

(* Refinement relation for uvalues *)
(* SAZ: Which way is the RefineConcrete case supposed to go?  I'm expecting that the left-hand-side
   must be "bigger" than the right-hand-side.  

   Does this do the right thing with respect to uvalues that can raise undefined behavior?
*)
Variant refine_uvalue: uvalue -> uvalue -> Prop :=
| UndefPoison: forall uv, refine_uvalue UVALUE_Poison uv   (* CB / YZ: TODO, type for poison? *)
| RefineConcrete: forall uv1 uv2, uv2 <> UVALUE_Poison -> (forall (dv:dvalue), concretize uv2 dv -> concretize uv1  dv) -> refine_uvalue uv1 uv2
.
Hint Constructors refine_uvalue : core.

Instance refine_uvalue_Reflexive : Reflexive refine_uvalue.
Proof.
  repeat intro.
  destruct x; try (apply RefineConcrete;[intro; inversion H|auto];fail).
  apply UndefPoison.
Qed.

Lemma refine_poison : forall uv, refine_uvalue uv UVALUE_Poison -> uv = UVALUE_Poison.
Proof.
  intros.
  inv H.
  - reflexivity.
  - contradiction H0.
    reflexivity.
Qed.

Instance refine_uvalue_Transitive : Transitive refine_uvalue.
Proof.
  repeat intro.
  inversion H; subst.
  - inversion H0; subst.
    econstructor.
    econstructor.
  - inversion H0; subst.
    apply refine_poison in H. subst. econstructor.
    apply RefineConcrete. intros. assumption. auto. 
Qed.

Infix"×" := prod_rel (at level 90, left associativity).

Definition TT {A} : relation A := fun _ _ => True.

(* Refinement of uninterpreted mcfg *)
Definition refine_L0: relation (itree L0 uvalue) := eutt refine_uvalue.

(* Refinement of mcfg after jumps *)
Definition refine_res1 : relation (block_id * uvalue)
  := TT × refine_uvalue.

Definition refine_L1 : relation (itree L1 (block_id * uvalue))
  := eutt refine_res1.

(* Refinement of mcfg after globals *)
Definition refine_res2 : relation (global_env * (block_id * uvalue))
  := TT × refine_res1.

Definition refine_L2 : relation (itree L2 (global_env * (block_id * uvalue)))
  := eutt refine_res2.

(* Refinement of mcfg after locals *)
Definition refine_res3 : relation (local_env * lstack * (global_env * (block_id * uvalue)))
  := TT × refine_res2.

Definition refine_L3 : relation (itree L3 (local_env * stack * (global_env * (block_id * uvalue))))
  := eutt refine_res3.

(* For multiple CFG, after interpreting [LocalE] and [MemoryE] and [IntrinsicE] that are memory intrinsics *)
Definition refine_res4 : relation (memory_stack * (local_env * stack * (global_env * (block_id * uvalue))))
  := TT × refine_res3.

Definition refine_L4 : relation (itree L4 (memory_stack * (local_env * stack * (global_env * (block_id * uvalue)))))
  := eutt refine_res4.

(* Refinement for after interpreting pick. *)
(* SAZ: we still want the "bigger" set to be on the left so every thing in ts' should be found in ts, right? *)
Definition refine_L5 : relation ((itree L5 (memory_stack * (local_env * stack * (global_env * (block_id * uvalue))))) -> Prop)
  := fun ts ts' => forall t', ts' t' -> exists t, ts t /\ eutt refine_res4 t t'.

(*
Definition refine_res4 : relation (memory * (local_env * stack * (global_env * dvalue)))
  := TT × (TT × (TT × refine_dvalue)).
 *)

Definition refine_L6 : relation ((itree L6 (memory_stack * (local_env * stack * (global_env * (block_id * uvalue))))) -> Prop)
  := fun ts ts' => forall t', ts' t' -> exists t, ts t /\ eutt refine_res4 t t'.

End Make.
