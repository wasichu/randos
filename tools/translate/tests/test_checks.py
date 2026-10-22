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
    # CJK is dense: "connecting" is two characters.
    assert checks.length("connecting", "连接", locale="zh")[0]
    assert not checks.length("connecting", "连接", locale="es")[0]


def test_script_matches_the_locale():
    assert checks.script("ja", "%{time} 残り")[0]
    assert checks.script("ru", "Найти rando")[0]
    assert checks.script("es", "Buscar un rando")[0]
    assert not checks.script("ru", "Find a friend")[0]
    assert not checks.script("ar", "Find")[0]
    # No letters at all, for a source that has some: a broken translation.
    assert not checks.script("ar", "& & &", "About")[0]
    assert checks.script("ar", "%{time}", "%{time}")[0]
    # Names copied from the English don't count against the script...
    assert checks.script("hi", "GitHub पर देखें", "View on GitHub")[0]
    # ...but English the source doesn't have still does.
    assert not checks.script("hi", "GitHub view पर", "View on GitHub")[0]


def test_one_translation_shaped_like_the_source():
    assert checks.shape("Time is up", "Die Zeit ist um")[0]
    assert not checks.shape("Time is up", "Die Zeit ist um.\noder\nEs ist vorbei.")[0]
    assert not checks.shape("About randos", "について(0)")[0]
    assert not checks.shape("Your rando", "Votre [0]")[0]
    assert checks.shape("Ages (18)", "Edad (18)")[0]
    # A heading stays a heading; a sentence keeps its end.
    assert not checks.shape("About randos", "Über randos.")[0]
    assert not checks.shape("Time is up", "時間切れです。")[0]
    assert checks.shape("Choose your languages.", "Elige tus idiomas.")[0]
    assert checks.shape("Something went wrong!", "¡Algo salió mal!")[0]
    assert checks.shape("Reconnecting audio…", "Reconectando el audio…")[0]


def test_protect_and_restore_round_trip():
    text, kept = protect("Looking for a rando speaking %{speaking_language}.")
    assert "%{" not in text and "rando" not in text
    assert restore(text, kept) == "Looking for a rando speaking %{speaking_language}."
