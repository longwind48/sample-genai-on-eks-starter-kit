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


def normalize(items, model="bedrock/gpt-6-astra"):
    data = {"model": model, "input": items}
    return asyncio.run(proxy_handler_instance.async_pre_call_hook(None, None, data, "aresponses"))["input"]


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

    def test_other_models_and_text_only_requests_are_unchanged(self):
        images = [call("a"), result("a", [IMAGE])]
        self.assertEqual(normalize(images, "bedrock/claude-sonnet-5"), images)
        text = [call("a"), result("a", "done")]
        self.assertEqual(normalize(text), text)


if __name__ == "__main__":
    unittest.main()
