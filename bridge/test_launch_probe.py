import unittest
from launch_probe import assistant_answer_observed

class LaunchEvidenceTests(unittest.TestCase):
    def test_prompt_text_cannot_count_as_assistant_reply(self):
        self.assertFalse(assistant_answer_observed([{'role':'user','text':'After the answer respond Bridge received ALPHA'}]))
        self.assertFalse(assistant_answer_observed([{'role':'assistant','text':'Waiting for input'}]))
        self.assertTrue(assistant_answer_observed([{'role':'assistant','text':'Bridge received ALPHA'}]))

    def test_teardown_helper_cannot_break_installed_signal_handlers(self):
        import ast,pathlib,threading,types
        source=ast.parse(pathlib.Path(__file__).with_name('launch_probe.py').read_text())
        main=next(node for node in source.body if isinstance(node,ast.FunctionDef) and node.name=='main')
        event=next(node for node in main.body if isinstance(node,ast.Assign) and any(isinstance(target,ast.Name) and target.id=='stop' for target in node.targets))
        signals=next(node for node in main.body if isinstance(node,ast.For) and isinstance(node.target,ast.Name) and node.target.id=='sig')
        cleanup=next(node for node in main.body if isinstance(node,ast.Try)).finalbody
        helper=next(node for node in cleanup if isinstance(node,ast.FunctionDef) and any(isinstance(child,ast.Call) and isinstance(child.func,ast.Attribute) and child.func.attr=='killpg' for child in ast.walk(node)))
        function=ast.FunctionDef(name='prepare_handlers',args=ast.arguments(posonlyargs=[],args=[],kwonlyargs=[],kw_defaults=[],defaults=[]),body=[event,signals,helper,ast.Return(value=ast.Name(id='stop',ctx=ast.Load()))],decorator_list=[])
        module=ast.fix_missing_locations(ast.Module(body=[function],type_ignores=[]))
        handlers=[]
        signal=types.SimpleNamespace(SIGINT=2,SIGTERM=15,SIGHUP=1,signal=lambda sig,handler:handlers.append(handler))
        namespace={'threading':threading,'signal':signal}
        exec(compile(module,'actual launcher signal/teardown bindings','exec'),namespace)
        stop_event=namespace['prepare_handlers']()
        for handler in handlers:handler()
        self.assertTrue(stop_event.is_set())
