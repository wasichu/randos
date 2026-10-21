from randos_translate import checks
from randos_translate.models import protect, restore


def test_placeholders_must_survive():
    assert checks.placeholders("%{time} remaining", "%{time} restantes")[0]
    ok, detail = checks.placeholders("%{time} remaining", "%{tiempo} restantes")
    assert not ok and "%{time}" in detail


def test_glossary_terms_stay():
    assert checks.glossary("Find a rando", "Buscar un rando")[0]
    assert not checks.glossary("Find a rando", "Buscar un desconocido")[0]
    assert checks.glossary("About randos", "Acerca de randos")[0]


def test_length_is_sane_and_buttons_tighter():
    assert checks.length("Find a rando", "Buscar un rando")[0]
    assert not checks.length("Short anonymous conversations", "")[0]
    assert not checks.length("End the call now", "x" * 40, button=True)[0]
    assert checks.length("End the call now", "x" * 40)[0]


def test_script_matches_the_locale():
    assert checks.script("ja", "%{time} 残り")[0]
    assert checks.script("ru", "Найти rando")[0]
    assert checks.script("es", "Buscar un rando")[0]
    assert not checks.script("ru", "Find a friend")[0]
    assert not checks.script("ar", "Find")[0]


def test_protect_and_restore_round_trip():
    text, kept = protect("Looking for a rando speaking %{speaking_language}.")
    assert "%{" not in text and "rando" not in text
    assert restore(text, kept) == "Looking for a rando speaking %{speaking_language}."
