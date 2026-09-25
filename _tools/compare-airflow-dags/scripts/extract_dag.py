"""Extract a structured inventory from an Airflow DAG file via static AST parsing.

No execution, no imports, no Airflow install required — works on any DAG source
from any Airflow version/instance. Emits JSON to stdout:

  {
    "dag": {...},          # DAG-level config (dag_id, schedule, default_args, ...)
    "tasks": [...],        # every operator/sensor/@task found, with all kwargs
    "task_groups": [...],  # TaskGroup labels
    "edges": [...],        # dependency edges [upstream, downstream]
    "functions": {...},    # module-level def/async def name -> source (for callable diffs)
    "dynamic": [...],      # tasks built inside loops/comprehensions/helpers (need manual review)
    "warnings": [...]      # anything the parser could not resolve
  }

Usage: python extract_dag.py <dag_file.py>
"""

import ast
import json
import sys


def _unparse(node):
    """Render an AST node back to source, tolerant of old Python."""
    try:
        return ast.unparse(node).strip()
    except Exception:
        return "<unparseable>"


def _is_operator_call(node):
    """A Call whose callable name ends in Operator or Sensor (or is TaskGroup)."""
    if not isinstance(node, ast.Call):
        return None
    name = _callable_name(node.func)
    if name and (name.endswith("Operator") or name.endswith("Sensor")):
        return name
    return None


def _callable_name(func):
    """Last component of a call target: foo.BashOperator -> BashOperator."""
    if isinstance(func, ast.Name):
        return func.id
    if isinstance(func, ast.Attribute):
        return func.attr
    return None


def _kwargs_dict(call):
    """All keyword args of a Call, value rendered verbatim as source."""
    out = {}
    for kw in call.keywords:
        if kw.arg is None:  # **kwargs splat
            out["**"] = _unparse(kw.value)
        else:
            out[kw.arg] = _unparse(kw.value)
    return out


def _literal_dict(node):
    """Best-effort: a dict literal -> {key: source}. Falls back to raw source."""
    if isinstance(node, ast.Dict):
        out = {}
        for k, v in zip(node.keys, node.values):
            key = _unparse(k).strip("'\"") if k is not None else "**"
            out[key] = _unparse(v)
        return out
    return {"<raw>": _unparse(node)}


class DagVisitor(ast.NodeVisitor):
    def __init__(self, source):
        self.source = source
        self.dag = {}
        self.tasks = []
        self.task_groups = []
        self.edges = []
        self.functions = {}
        self.dicts = {}           # variable name -> {key: source} for dict literals
        self.dynamic = []
        self.warnings = []
        self.var_to_taskid = {}   # variable name -> task_id (for edge resolution)
        self._loop_depth = 0

    # -- DAG-level config -------------------------------------------------
    def _capture_dag(self, call):
        kw = _kwargs_dict(call)
        # dag_id / schedule may also be positional; grab first positional as dag_id
        if call.args and "dag_id" not in kw:
            kw["dag_id"] = _unparse(call.args[0])
        # expand default_args if it's an inline dict
        for kwnode in call.keywords:
            if kwnode.arg == "default_args" and isinstance(kwnode.value, ast.Dict):
                kw["default_args"] = _literal_dict(kwnode.value)
        self.dag = kw

    def visit_Call(self, call):
        name = _callable_name(call.func)
        if name == "DAG":
            self._capture_dag(call)
        elif name == "TaskGroup":
            label = None
            if call.args:
                label = _unparse(call.args[0]).strip("'\"")
            for kw in call.keywords:
                if kw.arg == "group_id":
                    label = _unparse(kw.value).strip("'\"")
            if label:
                self.task_groups.append(label)
        else:
            op = _is_operator_call(call)
            if op:
                self._capture_task(call, op)
            elif name in ("chain", "cross_downstream"):
                self._capture_chain(call, name)
        self.generic_visit(call)

    def _capture_task(self, call, operator):
        kw = _kwargs_dict(call)
        task_id = kw.get("task_id", "<no task_id>").strip("'\"")
        record = {"task_id": task_id, "operator": operator, "args": kw}
        if self._loop_depth > 0:
            record["dynamic"] = True
            self.dynamic.append(record)
        else:
            self.tasks.append(record)

    def _capture_chain(self, call, name):
        parts = [_unparse(a) for a in call.args]
        self.edges.append({"kind": name, "operands": parts})

    # -- dependency operators >> << ---------------------------------------
    def visit_Expr(self, node):
        if isinstance(node.value, ast.BinOp) and isinstance(
            node.value.op, (ast.RShift, ast.LShift)
        ):
            self._flatten_shift(node.value)
        # method-style .set_downstream / .set_upstream
        if isinstance(node.value, ast.Call):
            m = _callable_name(node.value.func)
            if m in ("set_downstream", "set_upstream") and isinstance(
                node.value.func, ast.Attribute
            ):
                left = _unparse(node.value.func.value)
                # args may be a single task or a list/tuple of tasks — expand both
                rights = []
                for a in node.value.args:
                    rights.extend(self._operand_names(a))
                for r in rights:
                    if m == "set_downstream":
                        self.edges.append({"up": left, "down": r})
                    else:
                        self.edges.append({"up": r, "down": left})
        self.generic_visit(node)

    def _operand_names(self, node):
        """A shift/dependency operand is a task var, or a list of task vars."""
        if isinstance(node, (ast.List, ast.Tuple)):
            return [_unparse(e) for e in node.elts]
        return [_unparse(node)]

    def _flatten_shift(self, binop):
        """Turn a >> b >> [c, d] into ordered edges, honoring << direction."""
        # Gather the chain left-to-right as (operand, op) pairs
        seq = []

        def walk(n):
            if isinstance(n, ast.BinOp) and isinstance(n.op, (ast.RShift, ast.LShift)):
                walk(n.left)
                seq.append(n.op)
                walk(n.right)
            else:
                seq.append(n)

        walk(binop)
        # seq alternates operand, op, operand, op, ...
        operands = [x for x in seq if not isinstance(x, (ast.RShift, ast.LShift))]
        ops = [x for x in seq if isinstance(x, (ast.RShift, ast.LShift))]
        for i, op in enumerate(ops):
            left = self._operand_names(operands[i])
            right = self._operand_names(operands[i + 1])
            for l in left:
                for r in right:
                    if isinstance(op, ast.RShift):
                        self.edges.append({"up": l, "down": r})
                    else:
                        self.edges.append({"up": r, "down": l})

    # -- assignments: map var -> task_id, catch @task results -------------
    def visit_Assign(self, node):
        if len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
            var = node.targets[0].id
            if isinstance(node.value, ast.Call):
                op = _is_operator_call(node.value)
                if op:
                    kw = _kwargs_dict(node.value)
                    tid = kw.get("task_id", var).strip("'\"")
                    self.var_to_taskid[var] = tid
            elif isinstance(node.value, ast.Dict):
                self.dicts[var] = _literal_dict(node.value)
        self.generic_visit(node)

    # -- loops / comprehensions => dynamic generation ---------------------
    def visit_For(self, node):
        self._loop_depth += 1
        self.generic_visit(node)
        self._loop_depth -= 1

    def visit_ListComp(self, node):
        self._loop_depth += 1
        self.generic_visit(node)
        self._loop_depth -= 1

    def visit_While(self, node):
        self._loop_depth += 1
        self.generic_visit(node)
        self._loop_depth -= 1

    # -- functions: capture source + detect @task decorators --------------
    def _handle_func(self, node):
        self.functions[node.name] = ast.get_source_segment(self.source, node) or ""
        for dec in node.decorator_list:
            dname = _callable_name(dec.func if isinstance(dec, ast.Call) else dec)
            if dname == "task":
                task_id = node.name
                if isinstance(dec, ast.Call):
                    for kw in dec.keywords:
                        if kw.arg == "task_id":
                            task_id = _unparse(kw.value).strip("'\"")
                self.tasks.append(
                    {"task_id": task_id, "operator": "@task", "args": {}}
                )

    def visit_FunctionDef(self, node):
        self._handle_func(node)
        self.generic_visit(node)

    def visit_AsyncFunctionDef(self, node):
        self._handle_func(node)
        self.generic_visit(node)


def extract(path):
    with open(path, "r", encoding="utf-8") as f:
        source = f.read()
    try:
        tree = ast.parse(source)
    except SyntaxError as e:
        return {"error": f"SyntaxError parsing {path}: {e}"}
    v = DagVisitor(source)
    v.visit(tree)
    # resolve edge operand var names to task_ids where possible
    for e in v.edges:
        for side in ("up", "down"):
            if side in e and e[side] in v.var_to_taskid:
                e[side] = v.var_to_taskid[e[side]]
        if "operands" in e:
            e["operands"] = [v.var_to_taskid.get(o, o) for o in e["operands"]]
    # inline default_args if the DAG references a module-level dict by name
    da = v.dag.get("default_args")
    if isinstance(da, str) and da in v.dicts:
        v.dag["default_args"] = v.dicts[da]
    if not v.tasks and not v.dynamic:
        v.warnings.append("No tasks found — file may be empty or use an unrecognized pattern.")
    if v.dynamic:
        v.warnings.append(
            f"{len(v.dynamic)} task(s) built inside loops/comprehensions — "
            "static parse cannot enumerate every generated instance; review manually."
        )
    return {
        "dag": v.dag,
        "tasks": v.tasks,
        "task_groups": v.task_groups,
        "edges": v.edges,
        "functions": v.functions,
        "dicts": v.dicts,
        "dynamic": v.dynamic,
        "warnings": v.warnings,
    }


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: python extract_dag.py <dag_file.py>", file=sys.stderr)
        sys.exit(2)
    print(json.dumps(extract(sys.argv[1]), indent=2))