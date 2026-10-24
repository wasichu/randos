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


def test_a_look_alike_percent_sign_is_written_back():
    from randos_translate.models import placeholders

    assert placeholders("%{minutes} min", "٪{minutes} دقيقة") == "%{minutes} دقيقة"
    assert placeholders("%{minutes} min", "％{minutes}分") == "%{minutes}分"
    # Not a name the source has: left for the placeholder check to fail.
    assert placeholders("%{minutes} min", "٪{دقائق} دقيقة") == "٪{دقائق} دقيقة"


def test_the_name_in_arabic_letters_is_written_back():
    from randos_translate.models import tidy

    assert tidy("Your rando", "راندو الخاص بك") == "rando الخاص بك"
    assert tidy("About randos", "نبذة عن الراندوس") == "نبذة عن randos"


def test_the_name_in_urdu_hindi_and_bengali_letters_is_written_back():
    from randos_translate.models import tidy

    assert tidy("For your rando to open it.", "تاکہ آپ کا رانڈو اسے کھول سکے۔") == "تاکہ آپ کا rando اسے کھول سکے۔"
    assert tidy("randos", "رینڈوز") == "randos"
    assert tidy("For your rando to open it.", "ताकि आपका रैंडो इसे खोल सके।") == "ताकि आपका rando इसे खोल सके।"
    assert tidy("About randos", "রান্ডোস সম্পর্কে") == "randos সম্পর্কে"
    assert tidy("Your rando", "আপনার র\u200d্যান্ডো") == "আপনার rando"
    # A word that goes on is another word, or the name with a grammatical ending.
    assert tidy("random", "रैंडम") == "रैंडम"
    assert tidy("your rando's", "র্যান্ডোর") == "র্যান্ডোর"


def test_the_name_is_only_rewritten_as_a_whole_word_and_where_the_english_has_it():
    from randos_translate.models import tidy

    # Arabic attaches prepositions: kept, joined by a tatweel (و doesn't join).
    assert tidy("with your rando", "بالراندو الخاص بك") == "بـrando الخاص بك"
    assert tidy("and the randos", "والراندوس") == "وrandos"
    assert tidy("for your rando", "لراندو") == "لـrando"
    # What an earlier rule left glued is joined too.
    assert tidy("with your rando", "انقطع الاتصال بrando الخاص بك") == "انقطع الاتصال بـrando الخاص بك"
    # Inside another word, or where the English has no rando: left alone.
    assert tidy("with your rando", "ग्रैंडो") == "ग्रैंडो"
    assert tidy("Marlon Brando", "مارلون براندو") == "مارلون براندو"
    assert tidy("randos", "رینڈوس") == "randos"

