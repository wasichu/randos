// Text the hooks put on the page, translated by the server (gettext) and
// rendered as a data-labels JSON map on the hook's element
// (RandosWeb.HomeComponents). English is the fallback for a missing key.

export const labelsFrom = element => {
  try {
    const labels = JSON.parse(element?.dataset.labels || "{}")
    return labels && typeof labels === "object" ? labels : {}
  } catch (_error) {
    return {}
  }
}

// `%{name}` placeholders, as in gettext.
export const label = (labels, key, fallback, bindings = {}) =>
  Object.entries(bindings).reduce(
    (text, [name, value]) => text.replaceAll(`%{${name}}`, value),
    labels[key] ?? fallback,
  )
