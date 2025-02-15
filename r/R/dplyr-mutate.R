# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.


# The following S3 methods are registered on load if dplyr is present

mutate.arrow_dplyr_query <- function(.data,
                                     ...,
                                     .keep = c("all", "used", "unused", "none"),
                                     .before = NULL,
                                     .after = NULL) {
  call <- match.call()
  exprs <- ensure_named_exprs(quos(...))

  .keep <- match.arg(.keep)
  .before <- enquo(.before)
  .after <- enquo(.after)

  if (.keep %in% c("all", "unused") && length(exprs) == 0) {
    # Nothing to do
    return(.data)
  }

  .data <- as_adq(.data)

  # Restrict the cases we support for now
  if (length(dplyr::group_vars(.data)) > 0) {
    # mutate() on a grouped dataset does calculations within groups
    # This doesn't matter on scalar ops (arithmetic etc.) but it does
    # for things with aggregations (e.g. subtracting the mean)
    return(abandon_ship(call, .data, "mutate() on grouped data not supported in Arrow"))
  }

  mask <- arrow_mask(.data)
  results <- list()
  for (i in seq_along(exprs)) {
    # Iterate over the indices and not the names because names may be repeated
    # (which overwrites the previous name)
    new_var <- names(exprs)[i]
    results[[new_var]] <- arrow_eval(exprs[[i]], mask)
    if (inherits(results[[new_var]], "try-error")) {
      msg <- handle_arrow_not_supported(
        results[[new_var]],
        as_label(exprs[[i]])
      )
      return(abandon_ship(call, .data, msg))
    } else if (!inherits(results[[new_var]], "Expression") &&
      !is.null(results[[new_var]])) {
      # We need some wrapping to handle literal values
      if (length(results[[new_var]]) != 1) {
        msg <- paste0("In ", new_var, " = ", as_label(exprs[[i]]), ", only values of size one are recycled")
        return(abandon_ship(call, .data, msg))
      }
      results[[new_var]] <- Expression$scalar(results[[new_var]])
    }
    # Put it in the data mask too
    mask[[new_var]] <- mask$.data[[new_var]] <- results[[new_var]]
  }

  old_vars <- names(.data$selected_columns)
  # Note that this is names(exprs) not names(results):
  # if results$new_var is NULL, that means we are supposed to remove it
  new_vars <- names(exprs)

  # Assign the new columns into the .data$selected_columns
  for (new_var in new_vars) {
    .data$selected_columns[[new_var]] <- results[[new_var]]
  }

  # Deduplicate new_vars and remove NULL columns from new_vars
  new_vars <- intersect(new_vars, names(.data$selected_columns))

  # Respect .before and .after
  if (!quo_is_null(.before) || !quo_is_null(.after)) {
    new <- setdiff(new_vars, old_vars)
    .data <- dplyr::relocate(.data, !!new, .before = !!.before, .after = !!.after)
  }

  # Respect .keep
  if (.keep == "none") {
    .data$selected_columns <- .data$selected_columns[new_vars]
  } else if (.keep != "all") {
    # "used" or "unused"
    used_vars <- unlist(lapply(exprs, all.vars), use.names = FALSE)
    if (.keep == "used") {
      .data$selected_columns[setdiff(old_vars, used_vars)] <- NULL
    } else {
      # "unused"
      .data$selected_columns[intersect(old_vars, used_vars)] <- NULL
    }
  }
  # Even if "none", we still keep group vars
  ensure_group_vars(.data)
}
mutate.Dataset <- mutate.ArrowTabular <- mutate.arrow_dplyr_query

transmute.arrow_dplyr_query <- function(.data, ...) {
  dots <- check_transmute_args(...)
  dplyr::mutate(.data, !!!dots, .keep = "none")
}
transmute.Dataset <- transmute.ArrowTabular <- transmute.arrow_dplyr_query

# This function is a copy of dplyr:::check_transmute_args at
# https://github.com/tidyverse/dplyr/blob/master/R/mutate.R
check_transmute_args <- function(..., .keep, .before, .after) {
  if (!missing(.keep)) {
    abort("`transmute()` does not support the `.keep` argument")
  }
  if (!missing(.before)) {
    abort("`transmute()` does not support the `.before` argument")
  }
  if (!missing(.after)) {
    abort("`transmute()` does not support the `.after` argument")
  }
  enquos(...)
}

ensure_named_exprs <- function(exprs) {
  # Check for unnamed expressions and fix if any
  unnamed <- !nzchar(names(exprs))
  # Deparse and take the first element in case they're long expressions
  names(exprs)[unnamed] <- map_chr(exprs[unnamed], as_label)
  exprs
}
