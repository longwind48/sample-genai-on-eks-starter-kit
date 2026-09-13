"""Run with uv run --with litellm==1.100.1 codex_compat_test.py."""

import asyncio
import copy
import unittest

from codex_compat import proxy_handler_instance


IMAGE = {"type": "input_image", "image_url": "data:image/png;base64,original", "detail": "original"}


def call(call_id):
    return {"type": "function_call", "call_id": call_id, "name": "view_image", "arguments": "{}"}


def result(call_id, output):
    return {"type": "function_call_output", "call_id": call_id, "output": output}


def adapt(data):
    return asyncio.run(proxy_handler_instance.async_pre_call_hook(None, None, data, "aresponses"))


def normalize(items, model="bedrock/gpt-6-astra"):
    return adapt({"model": model, "input": items})["input"]


class ImageToolResultsTest(unittest.TestCase):
    def test_image_only_result_keeps_call_and_image(self):
        items = normalize([call("a"), result("a", [IMAGE])])
        self.assertEqual(len(items), 3)
        self.assertEqual(items[1]["call_id"], "a")
        self.assertIsInstance(items[1]["output"], str)
        self.assertEqual(items[2]["role"], "user")
        self.assertEqual(items[2]["content"][1], IMAGE)
        self.assertIn("a", items[2]["content"][0]["text"])
        self.assertIn("tool output", items[2]["content"][0]["text"])

    def test_text_and_image_details_are_preserved_without_mutating_history(self):
        text = {"type": "input_text", "text": "Screenshot from the test tool."}
        original = [call("a"), result("a", [text, IMAGE])]
        before = copy.deepcopy(original)
        items = normalize(original)
        self.assertEqual(items[1]["output"], [text])
        self.assertEqual(items[2]["content"][1], IMAGE)
        self.assertEqual(original, before)

    def test_parallel_results_stay_together_before_image_message(self):
        items = normalize([call("a"), call("b"), result("a", [IMAGE]), result("b", "done")])
        self.assertEqual([item["type"] for item in items], [
            "function_call", "function_call", "function_call_output", "function_call_output", "message"
        ])
        self.assertEqual(items[3]["output"], "done")

    def test_other_models_and_text_only_inputs_are_unchanged(self):
        images = [call("a"), result("a", [IMAGE])]
        self.assertEqual(normalize(images, "bedrock/claude-sonnet-5"), images)
        text = [call("a"), result("a", "done")]
        self.assertEqual(normalize(text), text)


class CompactionToolHistoryTest(unittest.TestCase):
    def test_missing_or_empty_tools_with_history_get_a_placeholder(self):
        for tools in [None, []]:
            with self.subTest(tools=tools):
                data = {"model": "bedrock/gpt-6-astra", "input": [call("a"), result("a", "done")]}
                if tools is not None:
                    data["tools"] = tools
                before = copy.deepcopy(data)
                adapted = adapt(data)
                self.assertEqual(adapted["input"], before["input"])
                self.assertEqual(data, before)
                self.assertEqual(len(adapted["tools"]), 1)
                self.assertEqual(adapted["tools"][0]["type"], "function")
                self.assertEqual(adapted["tools"][0]["parameters"]["type"], "object")

    def test_existing_tool_definitions_are_preserved(self):
        data = {
            "model": "bedrock/gpt-6-astra",
            "input": [call("a"), result("a", "done")],
            "tools": [{"type": "function", "name": "view_image", "parameters": {"type": "object"}}],
        }
        self.assertIs(adapt(data), data)

    def test_plain_text_and_other_models_do_not_get_tools(self):
        for data in [
            {"model": "bedrock/gpt-6-astra", "input": [{"role": "user", "content": "Hello"}]},
            {"model": "bedrock/claude-sonnet-5", "input": [call("a"), result("a", "done")]},
        ]:
            self.assertIs(adapt(data), data)
            self.assertNotIn("tools", data)


if __name__ == "__main__":
    unittest.main()
