# adf-to-md.jq — Convert Atlassian Document Format to Markdown using jq
#
# Single mode: jq -r -f adf-to-md.jq <<< '{"type":"doc",...}'
# Batch mode:  jq -r '[.[] | @json | fromjson | include "adf-to-md"]' (not used)
#
# Instead, batch is handled by the calling code: wrap each ADF in a call.

def adf_marks:
  # Apply marks (bold, italic, code, link) around text
  . as $node |
  $node.text // "" |
  if $node.marks then
    reduce $node.marks[] as $mark (.;
      if $mark.type == "strong" then "**\(.)** "
      elif $mark.type == "em" then "_\(.)_"
      elif $mark.type == "code" then "`\(.)`"
      elif $mark.type == "link" then "[\(.)](\($mark.attrs.href // ""))"
      else .
      end
    )
  else .
  end;

def adf_inline:
  # Convert an inline node (text, hardBreak, mention, emoji, etc.)
  if .type == "text" then adf_marks
  elif .type == "hardBreak" then "\n"
  elif .type == "mention" then "@\(.attrs.text // .attrs.id // "unknown")"
  elif .type == "emoji" then .attrs.shortName // ""
  elif .type == "inlineCard" then "[\(.attrs.url // "link")](\(.attrs.url // ""))"
  else .text // ""
  end;

def adf_inlines:
  # Join all inline children of a block node
  [.content[]? | adf_inline] | join("");

def adf_node:
  # Convert a block-level ADF node to markdown lines
  if .type == "doc" then
    [.content[]? | adf_node] | join("\n\n")

  elif .type == "paragraph" then
    adf_inlines

  elif .type == "heading" then
    (.attrs.level // 1) as $level |
    ("#" * $level) + " " + adf_inlines

  elif .type == "bulletList" then
    [.content[]? |
      "- " + ([.content[]? | adf_inlines] | join("\n  "))
    ] | join("\n")

  elif .type == "orderedList" then
    [.content[]? | to_entries[] |
      "\(.key + 1). " + ([.value.content[]? | adf_inlines] | join("\n   "))
    ] | join("\n")

  elif .type == "codeBlock" then
    "```\(.attrs.language // "")\n" + ([.content[]? | .text // ""] | join("")) + "\n```"

  elif .type == "blockquote" then
    [.content[]? | "> " + adf_inlines] | join("\n")

  elif .type == "rule" then
    "---"

  elif .type == "mediaSingle" then
    [.content[]? |
      if .type == "media" then
        if .attrs.url then "![\(.attrs.alt // "image")](\(.attrs.url))"
        elif .attrs.id then "(attachment: \(.attrs.id))"
        else "(media)"
        end
      else ""
      end
    ] | join("")

  elif .type == "table" then
    [.content[]? |
      if .type == "tableRow" or .type == "tableHeader" then
        "| " + ([.content[]? | adf_inlines] | join(" | ")) + " |"
      else ""
      end
    ] | . as $rows |
    if length > 0 then
      # Insert separator after first row (header)
      [$rows[0],
       ($rows[0] | gsub("[^|]"; "-")),
       $rows[1:][]
      ] | join("\n")
    else ""
    end

  elif .type == "panel" then
    "> **\(.attrs.panelType // "info")**: " + ([.content[]? | adf_inlines] | join("\n> "))

  elif .type == "expand" then
    "<details><summary>\(.attrs.title // "Details")</summary>\n\n" +
    ([.content[]? | adf_node] | join("\n\n")) +
    "\n</details>"

  else
    # Unknown node — try to extract text content
    if .content then [.content[]? | adf_node] | join("\n")
    elif .text then .text
    else ""
    end
  end;

# Entry point
adf_node
