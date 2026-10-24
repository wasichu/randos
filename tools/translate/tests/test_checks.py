import unicodedata

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
    # Inside another word it doesn't count ("esperando" holds "rando").
    assert not checks.glossary("waiting on your rando", "esperando a tu interlocutor")[0]
    assert checks.glossary("waiting on your rando", "esperando a tu rando")[0]
    assert not checks.glossary("waiting on your rando", "en attendant votre randonnée")[0]
    assert checks.glossary("Find a rando", "Bir randoyu bul", "tr")[0]
    assert checks.glossary("Find a rando", "rando-এর অপেক্ষায়", "bn")[0]
    assert checks.glossary("Find a rando", "randoを探す")[0]


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


def test_a_final_full_stop_the_source_lacks_can_be_dropped():
    assert checks.without_final_stop("waiting for them", "待っています。") == "待っています"
    assert checks.without_final_stop("I'm 18+", "동의합니다.") == "동의합니다"
    # The source ends a sentence too: the stop stays.
    assert checks.without_final_stop("You left.", "Saliste.") == "Saliste."


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


def test_the_new_locales_scripts():
    assert checks.script("ur", "ایک rando تلاش کریں", "Find a rando")[0]
    assert checks.script("fa", "یک rando پیدا کنید", "Find a rando")[0]
    assert not checks.script("ur", "एक rando खोजें", "Find a rando")[0]
    # Vietnamese, composed or decomposed, is Latin.
    assert checks.script("vi", "Tìm một rando", "Find a rando")[0]
    assert checks.script("vi", unicodedata.normalize("NFD", "Tiếng Việt"), "Vietnamese")[0]


def test_english_left_as_it_was_fails_unless_it_is_a_short_label():
    assert not checks.unchanged("Looking for a rando", "looking for a rando")[0]
    assert checks.unchanged("Status", "Status")[0]
    assert checks.unchanged("Looking for a rando", "Naghahanap ng rando")[0]


def test_urdu_and_persian_dont_use_arabic_letter_forms():
    assert not checks.letter_forms("fa", "يک rando پيدا کنيد")[0]
    assert not checks.letter_forms("ur", "ایک rando تلاش كریں")[0]
    assert checks.letter_forms("fa", "یک rando پیدا کنید")[0]
    assert checks.letter_forms("ar", "ابحث عن rando لكي")[0]


def test_a_filipino_linker_keeps_the_term():
    assert checks.glossary("waiting on your rando", "hinihintay ang iyong randong kausap", "fil")[0]


def test_no_number_the_english_doesnt_have():
    assert not checks.numbers("%{minutes}+ min", "%{minutes} + 1 دقيقة")[0]
    assert checks.numbers("I am 18 or older", "Tengo 18 años o más")[0]
    # Localized digits are the same number; a spelled-out one counts.
    assert checks.numbers("I am 18 or older", "من ۱۸ سال یا بیشتر دارم")[0]
    assert checks.numbers("Pick at least one language to hear", "聞くための言語を1つ以上選んでください")[0]


def test_a_printf_placeholder_the_source_lacks_fails():
    assert not checks.placeholders("check", "Error sa pagbasa ng talaksang '%s': %s")[0]
    assert checks.placeholders("Done", "Hecho")[0]


def test_an_exclamation_mark_the_source_lacks_can_be_dropped_too():
    assert checks.without_final_stop("Hello", "Hola!") == "Hola"
