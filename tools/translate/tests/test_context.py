"""A string's translator comment reaches the models that take context (and
the judge), and only those strings get the changed prompt."""

from randos_translate import po, scoring
from randos_translate.models.mlx_chat import prompt_messages, with_context

ABOUT = "The page that explains what randos is (\"about us\"), not \"approximately\"."


def test_a_source_s_context_is_its_comment_else_its_msgctxt():
    assert po.Source("About", comment=ABOUT).context == ABOUT
    assert po.Source("End", "button").context == "A button label."
    assert po.Source("starting", "connection state").context == "A connection state label."
    assert po.Source("Cancel").context == ""


def test_hy_mt2_gets_the_context_as_background_information():
    ask = prompt_messages("hy-mt2", "About", "en", "es", ABOUT)[0]["content"]
    assert "[Background Information]\n" + ABOUT in ask
    assert ask.endswith("[Source Text]\nAbout")
    assert "rando translates to rando" in ask


def test_without_a_context_hy_mt2_s_prompt_is_unchanged():
    ask = prompt_messages("hy-mt2", "Cancel", "en", "es")[0]["content"]
    assert "Background" not in ask
    assert ask.endswith("additional explanation**:\n\nCancel")


def test_translategemma_gets_the_context_just_before_the_text():
    rendered = "<start_of_turn>user\nYou are a professional translator.\nPlease translate the following English text into Spanish:\n\n\nAbout"
    out = with_context(rendered, ABOUT)
    assert f"Context (for you, not to translate): {ABOUT}\nPlease translate the following" in out
    assert with_context(rendered, "") == rendered


def test_the_judge_sees_the_comment_and_rejudges_when_it_changes():
    assert scoring.judge_context("button", "Button: hang up.") == (
        "\nIt is a button label: it must be short.\nWhere it appears: Button: hang up.\n"
    )
    assert scoring.judge_context(None, "") == ""
    # A judgement from before comments existed saw only the button rule.
    old = {"msgctxt": "button", "scores": {"judge": {"score": 7}}}
    assert scoring.judged_context(old, "judge") == scoring.judge_context("button", "")
    new = {"msgctxt": None, "scores": {"judge": {"score": 7, "context": "\nWhere it appears: x\n"}}}
    assert scoring.judged_context(new, "judge") == "\nWhere it appears: x\n"
