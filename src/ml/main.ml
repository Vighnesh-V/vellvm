(* A main harness for Coq-extracted LLVM Transformations *)
open Arg
open Assert
open Driver

(* test harness ------------------------------------------------------------- *)
exception Ran_tests
let suite = ref Test.suite
let exec_tests () =
  Platform.configure();
  let outcome = run_suite !suite in
  Printf.printf "%s\n" (outcome_to_string outcome);
  raise Ran_tests

let test_pp_dir dir =
  Platform.configure();
  let suite = [Test.pp_test_of_dir dir] in
  let outcome = run_suite suite in
  Printf.printf "%s\n" (outcome_to_string outcome);
  raise Ran_tests


(* Use the --test option to run unit tests and the quit the program. *)
let args =
  [ ("--test", Unit exec_tests, "run the test suite, ignoring other inputs")
  ; ("--test-pp-dir", String test_pp_dir, "run the parsing/pretty-printing tests on all .ll files in the given directory")
  ; ("-op", Set_string Platform.output_path, "set the path to the output files directory  [default='output']")
  ; ("-v", Set Platform.verbose, "enables more verbose compilation output")] 

let files = ref []
let _ =
  Printf.printf "(* -------- Vellvm Test Harness -------- *)\n%!";
  try
    Arg.parse args (fun filename -> files := filename :: !files)
      "USAGE: ./vellvm [options] <files>\n";
    Platform.configure ();
    process_files !files

  with Ran_tests -> ()


