"""randos is a name, always lowercase: the post-step that makes every
contestant's output so, and the check that fails a capital from now on."""

from randos_translate import checks
from randos_translate.models import brand_case


def test_lowercases_the_brand_wherever_a_model_capitalized_it():
    assert brand_case("Randos est un lieu") == "randos est un lieu"
    assert brand_case("Randoslar hakkında") == "randoslar hakkında"
    assert brand_case("Randosは場所です") == "randosは場所です"
    assert brand_case("Il prossimo Rando") == "Il prossimo rando"
    assert brand_case("RANDOS") == "randos"


def test_leaves_every_other_word_alone():
    assert brand_case("Random choices") == "Random choices"
    assert brand_case("Encontrar un rando") == "Encontrar un rando"
    assert brand_case("Ein Brando") == "Ein Brando"


def test_the_glossary_check_is_case_sensitive():
    assert checks.glossary("randos is a place", "randos est un lieu")[0]
    ok, detail = checks.glossary("randos is a place", "Randos est un lieu")
    assert not ok and detail == "capitalized ['randos']"
    ok, detail = checks.glossary("Your rando", "Votre partenaire")
    assert not ok and detail == "missing ['rando']"


def test_the_sources_ellipsis_stays_one_character():
    from randos_translate.models import ellipsis, tidy

    assert ellipsis("Looking for a rando…", "Buscando un rando...") == "Buscando un rando…"
    # Only where the English has one: "..." elsewhere is the model's to keep.
    assert ellipsis("Wait", "Espera...") == "Espera..."
    assert tidy("Connecting…", "Randos se conecta...") == "randos se conecta…"
