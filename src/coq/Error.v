(* -------------------------------------------------------------------------- *
 *                     Vellvm - the Verified LLVM project                     *
 *                                                                            *
 *     Copyright (c) 2017 Steve Zdancewic <stevez@cis.upenn.edu>              *
 *                                                                            *
 *   This file is distributed under the terms of the GNU General Public       *
 *   License as published by the Free Software Foundation, either version     *
 *   3 of the License, or (at your option) any later version.                 *
 ---------------------------------------------------------------------------- *)

From Coq Require Import String.
Require Import ExtLib.Structures.Monads.
Require Export ExtLib.Data.Monads.EitherMonad.

From ITree Require Import
     ITree
     Events.Exception.

Notation err := (sum string).

Instance Monad_err : Monad err := Monad_either string.
Instance Exception_err : MonadExc string err := Exception_either string.


Definition trywith {E A:Type} {F} `{Monad F} `{MonadExc E F} (e:E) (o:option A) : F A :=
    match o with
    | Some x => ret x
    | None => raise e
    end.
Hint Unfold trywith: core.
Arguments trywith _ _ _ _ _: simpl nomatch.

Definition failwith {A:Type} {F} `{Monad F} `{MonadExc string F} (s:string) : F A := raise s.
Hint Unfold failwith: core.
Arguments failwith _ _ _ _: simpl nomatch.

(* SAZ:
   I believe that these refer to "undefined behavior", not "undef" values.  
   Raname them to "UB" and "UB_or_err"?
*)
Definition undef := err.
Definition undef_or_err := eitherT string err.

Instance Monad_undef_or_err : Monad undef_or_err.
unfold undef_or_err. typeclasses eauto.
Defined.
