import Lean.Data.Json
import PsacModel

/-!
Executable oracle for the differential harness. Reads a scenario JSON, evaluates it
from scratch after each update batch (the specification), cross-checks `propagate`
against `eval` on every step (a runtime instance of `propagate_correct`), and prints
canonical JSON that must match the CL runtime's output byte-for-byte.
-/

open PsacModel
open Lean (Json)

structure Scenario where
  mods : List (String × Int)
  nodes : List Node
  updates : List (List (String × Int))

def parseOp : String → Except String Op
  | "add" => .ok .add
  | "sub" => .ok .sub
  | "mul" => .ok .mul
  | "max" => .ok .max
  | "min" => .ok .min
  | o => .error s!"unknown op: {o}"

def parseScenario (j : Json) : Except String Scenario := do
  let modsArr ← (← j.getObjVal? "mods").getArr?
  let mods ← modsArr.toList.mapM fun m => do
    let name ← (← m.getObjVal? "name").getStr?
    let value ← (← m.getObjVal? "value").getInt?
    pure (name, value)
  let nodesArr ← (← j.getObjVal? "nodes").getArr?
  let nodes ← nodesArr.toList.mapM fun n => do
    let op ← parseOp (← (← n.getObjVal? "op").getStr?)
    let ins ← (← n.getObjVal? "inputs").getArr?
    let (in1, in2) ← match ins.toList with
      | [a, b] => do pure ((← a.getStr?), (← b.getStr?))
      | _ => throw "expected exactly two inputs"
    let out ← (← n.getObjVal? "out").getStr?
    pure { op, in1, in2, out : Node }
  let updArr ← (← j.getObjVal? "updates").getArr?
  let updates ← updArr.toList.mapM fun batch => do
    let bArr ← batch.getArr?
    bArr.toList.mapM fun u => do
      let m ← (← u.getObjVal? "mod").getStr?
      let v ← (← u.getObjVal? "value").getInt?
      pure (m, v)
  pure { mods, nodes, updates }

def applyWrites (σ : Store) (writes : List (String × Int)) : Store :=
  writes.foldl (fun σ nv => σ.set nv.1 nv.2) σ

def sortedNames (sc : Scenario) : List String :=
  ((sc.mods.map (·.1) ++ sc.nodes.map (·.out)).toArray.qsort (· < ·)).toList

def renderVals (vals : List (String × Int)) : String :=
  "{\"values\":{"
    ++ String.intercalate "," (vals.map fun nv => "\"" ++ nv.1 ++ "\":" ++ toString nv.2)
    ++ "}}"

def renderSteps (steps : List (List (String × Int))) : String :=
  "{\"steps\":[" ++ String.intercalate "," (steps.map renderVals) ++ "]}"

def main (args : List String) : IO UInt32 := do
  let some path := args.head? | do
    IO.eprintln "usage: oracle <scenario.json>"
    return 1
  let txt ← IO.FS.readFile path
  match Json.parse txt >>= parseScenario with
  | .error e =>
    IO.eprintln s!"scenario error: {e}"
    return 1
  | .ok sc =>
    let ns := sortedNames sc
    let prog := sc.nodes
    let mut σin : Store := applyWrites (fun _ => 0) sc.mods
    let mut σfull := eval σin prog
    let mut steps := [ns.map fun n => (n, σfull n)]
    for batch in sc.updates do
      let σin' := applyWrites σin batch
      let full := eval σin' prog
      let inc := propagate σfull σin' prog
      for n in ns do
        if inc n ≠ full n then
          IO.eprintln s!"propagate/eval mismatch at {n}: {inc n} vs {full n}"
          return 2
      σin := σin'
      σfull := full
      steps := (ns.map fun n => (n, full n)) :: steps
    IO.println (renderSteps steps.reverse)
    return 0
