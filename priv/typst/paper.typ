// The only way a layout reaches data. Values arrive as display strings; none of them is ever evaluated.
#let paper-data = json("payload.json")
#let paper-theme = json("theme.json")

#let paper-mark(kind, key, edge) = [#metadata((kind: kind, key: key, edge: edge)) <paper-mark>]

#let paper-setup(body) = {
  set document(title: paper-data.title, date: none)
  set page(
    paper: paper-theme.paper,
    margin: (x: paper-theme.margin_x * 1pt, y: paper-theme.margin_y * 1pt),
    footer: context align(center, text(size: 8pt, counter(page).display("1 / 1", both: true))),
  )
  set text(
    font: paper-theme.body_font,
    size: paper-theme.body_size * 1pt,
    lang: paper-data.locale,
    hyphenate: false,
  )
  set par(justify: false)
  show heading: set text(font: paper-theme.heading_font, fill: rgb(paper-theme.accent))
  body
}

#let paper-block(kind, key, body) = {
  paper-mark(kind, key, "start")
  block(width: 100%, { set text(hyphenate: false); body })
  paper-mark(kind, key, "end")
}

#let paper-title() = heading(level: 1, outlined: false, paper-data.title)

#let paper-field(key) = paper-block("field", key)[*#paper-data.labels.at(key):* #paper-data.fields.at(key)]

#let paper-fields() = { for key in paper-data.field_order { paper-field(key) } }

#let paper-clause(key) = {
  let found = paper-data.clauses.filter(c => c.key == key)
  assert(found.len() == 1, message: "clause not in payload: " + key)
  paper-block("clause", key, found.first().text)
}

#let paper-clauses() = { for c in paper-data.clauses { paper-clause(c.key) } }

#let paper-table(name) = {
  let rows = paper-data.tables.at(name)
  let columns = paper-data.columns.at(name)
  paper-mark("table", name, "start")
  table(
    columns: columns.len(),
    table.header(..columns.map(c => strong(paper-data.labels.at(name + "." + c)))),
    ..rows.enumerate().map(((i, row)) => columns.enumerate().map(((j, c)) => {
      if j == 0 { [#paper-mark("row", name + "/" + str(i), "start")#row.at(c)] } else { row.at(c) }
    })).flatten(),
  )
  paper-mark("table", name, "end")
}

#let paper-tables() = { for name in paper-data.table_order { paper-table(name) } }

#let paper-finish() = {
  if sys.inputs.at("paper_marks", default: "0") == "1" {
    context pdf.attach("paper-marks.json", bytes(json.encode(
      query(<paper-mark>).map(m => {
        let p = m.location().position()
        (value: m.value, page: p.page, x: p.x / 1pt, y: p.y / 1pt)
      })
    )), mime-type: "application/json")
  }
}
