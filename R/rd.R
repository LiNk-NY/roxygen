#' @include tag-registry.R
#' @import stringr
NULL

register_tags(
  aliases = tag_value,
  author = tag_markdown,
  backref = tag_value,
  concept = tag_markdown,
  describeIn = tag_name_description,
  description = tag_markdown,
  details = tag_markdown,
  docType = tag_name,
  encoding = tag_value,
  evalRd = tag_code,
  example = tag_value,
  examples = tag_examples,
  family = tag_value,
  field = tag_name_description,
  format = tag_markdown,
  inheritParams = tag_value,
  keywords = tag_value,
  method = tag_words(2, 2),
  name = tag_value,
  md = tag_toggle,
  noRd = tag_toggle,
  note = tag_markdown,
  param = tag_name_description,
  rdname = tag_value,
  rawRd = tag_value,
  references = tag_markdown,
  return = tag_markdown,
  section = tag_markdown,
  seealso = tag_markdown,
  slot = tag_name_description,
  source = tag_markdown,
  title = tag_markdown_title,
  usage = tag_value
)

#' Roclet: make Rd files.
#'
#' This roclet is the workhorse of \pkg{roxygen}, producing the Rd files that
#' document that functions in your package.
#'
#' @family roclets
#' @seealso \code{vignette("rd", package = "roxygen2")}
#' @export
rd_roclet <- function() {
  new_roclet(list(), "rd_roclet")
}

#' @export
roc_process.rd_roclet <- function(roclet, parsed, base_path, options = list()) {
  # Convert each block into a topic, indexed by filename
  topics <- list()
  for (block in parsed$blocks) {
    if (length(block) == 0)
      next

    rd <- block_to_rd(block, base_path, parsed$env)
    if (is.null(rd))
      next

    if (rd$filename %in% names(topics)) {
      topics[[rd$filename]]$add(rd)
    } else {
      topics[[rd$filename]] <- rd
    }
  }

  # Drop any topics that don't have a title
  for (topic in names(topics)) {
    if (!topics[[topic]]$is_valid()) {
      warning(topic, " is missing name/title. Skipping", call. = FALSE)
      topics[[topic]] <- NULL
    }
  }

  topics <- process_family(topics)
  topics <- process_inherit_params(topics)
  fix_params_order(topics)
}

block_to_rd <- function(block, base_path, env) {
  # Must start by processing templates
  block <- process_templates(block, base_path)

  if (!needs_doc(block)) {
    return()
  }

  name <- block$name %||% object_topic(block$object)
  if (is.null(name)) {
    block_warning(block, "Missing name")
    return()
  }

  # Note that order of operations here doesn't matter: fields are
  # ordered by RoxyFile$format()
  rd <- RoxyTopic$new()
  topic_add_name_aliases(rd, block, name)

  # Some fields added directly by roxygen internals
  fields <- Filter(is_roxy_field, block)
  rd$add(fields)

  topic_add_backref(rd, block)
  topic_add_doc_type(rd, block)
  topic_add_eval_rd(rd, block, env)
  topic_add_examples(rd, block, base_path)
  topic_add_fields(rd, block)
  topic_add_keyword(rd, block)
  topic_add_methods(rd, block)
  topic_add_params(rd, block)
  topic_add_simple_tags(rd, block)
  topic_add_sections(rd, block)
  topic_add_slots(rd, block)
  topic_add_usage(rd, block)
  topic_add_value(rd, block)

  describe_rdname <- topic_add_describe_in(rd, block, env)

  filename <- describe_rdname %||% block$rdname %||% nice_name(name)
  rd$filename <- paste0(filename, ".Rd")

  rd
}

#' @export
roc_output.rd_roclet <- function(roclet, results, base_path, options = list(),
                           check = TRUE) {
  man <- normalizePath(file.path(base_path, "man"))

  contents <- vapply(results, format, wrap = options$wrap,
    FUN.VALUE = character(1))

  paths <- file.path(man, names(results))
  mapply(write_if_different, paths, contents, MoreArgs = list(check = check))

  if (check) {
    # Automatically delete any files in man directory that were generated
    # by roxygen in the past, but weren't generated in this sweep.

    old_paths <- setdiff(dir(man, full.names = TRUE), paths)
    old_paths <- old_paths[!file.info(old_paths)$isdir]
    old_roxygen <- Filter(made_by_roxygen, old_paths)
    if (length(old_roxygen) > 0) {
      cat(paste0("Deleting ", basename(old_roxygen), collapse = "\n"), "\n", sep = "")
      unlink(old_roxygen)
    }
  }

  paths
}

#' @export
clean.rd_roclet <- function(roclet, base_path) {
  rd <- dir(file.path(base_path, "man"), full.names = TRUE)
  rd <- rd[!file.info(rd)$isdir]
  made_by_me <- vapply(rd, made_by_roxygen, logical(1))

  unlink(rd[made_by_me])
}


block_tags <- function(x, tag) {
  x[names(x) %in% tag]
}

needs_doc <- function(block) {
  # Does this block get an Rd file?
  if (any(names(block) == "noRd")) {
    return(FALSE)
  }

  key_tags <- c("description", "param", "return", "title", "example",
    "examples", "name", "rdname", "usage", "details", "introduction",
    "describeIn")

  any(names(block) %in% key_tags)
}

# Tag processing functions ------------------------------------------------

topic_add_backref <- function(topic, block) {
  backrefs <- block_tags(block, "backref") %||% block$srcref$filename

  for (backref in backrefs) {
    topic$add_simple_field("backref", backref)
  }
}

# Simple tags can be converted directly to fields
topic_add_simple_tags <- function(topic, block) {
  simple_tags <- c(
    "author", "concept", "description", "details", "encoding", "family",
    "format", "inheritParams", "note", "rawRd", "references",
    "seealso", "source", "title"
  )

  is_simple <- names(block) %in% simple_tags
  tag_values <- block[is_simple]
  tag_names <- names(block)[is_simple]

  for (i in seq_along(tag_values)) {
    topic$add_simple_field(tag_names[[i]], tag_values[[i]])
  }
}

topic_add_params <- function(topic, block) {
  # Used in process_inherit_params()
  if (is.function(block$object$value)) {
    formals <- formals(block$object$value)
    topic$add_simple_field("formals", names(formals))
  }

  process_def_tag(topic, block, "param")
}

topic_add_name_aliases <- function(topic, block, name) {
  tags <- block_tags(block, "aliases")

  if (length(tags) == 0) {
    aliases <- character()
  } else {
    aliases <- str_split(str_trim(unlist(tags, use.names = FALSE)), "\\s+")[[1]]
  }

  if (any(aliases == "NULL")) {
    # Don't add default aliases
    aliases <- aliases[aliases != "NULL"]
  } else {
    aliases <- unique(c(name, block$object$alias, aliases))
  }

  topic$add_simple_field("name", name)
  topic$add_simple_field("alias", aliases)
}


topic_add_methods <- function(topic, block) {
  obj <- block$object
  if (!inherits(obj, "rcclass")) return()

  methods <- obj$methods
  if (is.null(obj$methods)) return()

  desc <- lapply(methods, function(x) docstring(x$value@.Data))
  usage <- vapply(methods, function(x) {
    usage <- function_usage(x$value@name, formals(x$value@.Data))
    as.character(wrap_string(usage))
  }, character(1))

  has_docs <- !vapply(desc, is.null, logical(1))
  desc <- desc[has_docs]
  usage <- usage[has_docs]

  topic$add_simple_field("rcmethods", setNames(desc, usage))
}

topic_add_value <- function(topic, block) {
  tags <- block_tags(block, "return")

  for (tag in tags) {
    topic$add_simple_field("value", tag)
  }
}

topic_add_keyword <- function(topic, block) {
  tags <- block_tags(block, "keywords")
  keywords <- unlist(str_split(str_trim(tags), "\\s+"))

  topic$add_simple_field("keyword", keywords)
}

# Prefer explicit \code{@@usage} to a \code{@@formals} list.
topic_add_usage <- function(topic, block) {
  if (is.null(block$usage)) {
    usage <- wrap_string(object_usage(block$object))
  } else if (block$usage == "NULL") {
    usage <- NULL
  } else {
    # Treat user input as already escaped, otherwise they have no way
    # to enter \S4method etc.
    usage <- rd(block$usage)
  }
  topic$add_simple_field("usage", usage)
}

topic_add_slots <- function(topic, block) {
  process_def_tag(topic, block, "slot")
}

topic_add_fields <- function(topic, block) {
  process_def_tag(topic, block, "field")
}

# If \code{@@examples} is provided, use that; otherwise, concatenate
# the files pointed to by each \code{@@example}.
topic_add_examples <- function(topic, block, base_path) {
  examples <- block_tags(block, "examples")
  for (example in examples) {
    topic$add_simple_field("examples", example)
  }

  paths <- str_trim(unlist(block_tags(block, "example")))
  paths <- file.path(base_path, paths)

  for (path in paths) {
    # Check that haven't accidentally used example instead of examples
    nl <- str_count(path, "\n")
    if (any(nl) > 0) {
      block_warning(block, "@example spans multiple lines. Do you want @examples?")
      next
    }

    if (!file.exists(path)) {
      block_warning(block, "@example ", path, " doesn't exist")
      next
    }

    code <- readLines(path)
    examples <- escape_examples(code)

    topic$add_simple_field("examples", examples)
  }
}

topic_add_eval_rd <- function(topic, block, env) {
  tags <- block_tags(block, "evalRd")

  for (tag in tags) {
    tryCatch({
      expr <- parse(text = tag)
      out <- eval(expr, envir = env)
      topic$add_simple_field("rawRd", as.character(out))
    }, error = function(e) {
      block_warning(block, "@evalRd failed with error: ", e$message)
    })
  }
}

topic_add_sections <- function(topic, block) {
  sections <- block_tags(block, "section")

  for (section in sections) {
    pieces <- str_split(section, ":", n = 2)[[1]]

    title <- str_split(pieces[1], "\n")[[1]]
    if (length(title) > 1) {
      return(block_warning(
        block,
        "Section title spans multiple lines: \n", "@section ", title[1]
      ))
    }

    topic$add_field(roxy_field_section(pieces[1], pieces[2]))
  }
}

topic_add_doc_type <- function(topic, block) {
  doctype <- block$docType
  if (is.null(doctype)) return()

  topic$add_simple_field("docType", doctype)

  if (doctype == "package") {
    name <- block$name
    if (!str_detect(name, "-package")) {
      topic$add_simple_field("alias", package_suffix(name))
    }
  }

}

package_suffix <- function(name) {
  paste0(name, "-package")
}

process_tag <- function(block, tag, f = roxy_field, ...) {
  matches <- block[names(block) == tag]
  if (length(matches) == 0) return()

  lapply(matches, function(p) f(tag, p, ...))
}

# Name + description tags ------------------------------------------------------


process_def_tag <- function(topic, block, tag) {
  tags <- block[names(block) == tag]
  if (length(tags) == 0) return()

  desc <- str_trim(sapply(tags, "[[", "description"))
  names(desc) <- sapply(tags, "[[", "name")

  topic$add_simple_field(tag, desc)
}
