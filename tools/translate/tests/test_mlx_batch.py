"""The MLX translators send their prompts together (`MLXChat._batch`), in
chunks of `BATCH`, and keep the replies in order; no model is loaded."""

from types import SimpleNamespace

from randos_translate.models.mlx_chat import MLXChat


class Tokenizer:
    def apply_chat_template(self, messages, add_generation_prompt, tokenize):
        return "<bos>" + messages[0]["content"][0]["text"] if isinstance(messages[0]["content"], list) else "<bos>" + messages[0]["content"]

    def encode(self, text, add_special_tokens):
        assert add_special_tokens is False  # the template already has BOS
        return [ord(c) for c in text]


def chat(batch_size=2):
    model = MLXChat.__new__(MLXChat)
    model._style, model._tokenizer, model._model, model.BATCH = "translategemma", Tokenizer(), None, batch_size
    model.calls = []

    def batch_generate(_model, _tokenizer, prompts, max_tokens):
        model.calls.append(len(prompts))
        texts = ["".join(map(chr, p)).removeprefix("<bos>").upper() + "<end_of_turn>junk" for p in prompts]
        return SimpleNamespace(texts=texts)

    model._batch_generate = batch_generate
    return model


def test_prompts_go_together_in_chunks_and_replies_keep_their_order():
    model = chat(batch_size=2)
    assert model.translate(["one", "two", "three"], "es") == ["ONE", "TWO", "THREE"]
    assert model.calls == [2, 1]
    assert model.back_translate(["uno"], "es") == ["UNO"]
