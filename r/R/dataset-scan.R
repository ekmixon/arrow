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

#' Scan the contents of a dataset
#'
#' @description
#' A `Scanner` iterates over a [Dataset]'s fragments and returns data
#' according to given row filtering and column projection. A `ScannerBuilder`
#' can help create one.
#'
#' @section Factory:
#' `Scanner$create()` wraps the `ScannerBuilder` interface to make a `Scanner`.
#' It takes the following arguments:
#'
#' * `dataset`: A `Dataset` or `arrow_dplyr_query` object, as returned by the
#'    `dplyr` methods on `Dataset`.
#' * `projection`: A character vector of column names to select columns or a
#'    named list of expressions
#' * `filter`: A `Expression` to filter the scanned rows by, or `TRUE` (default)
#'    to keep all rows.
#' * `use_threads`: logical: should scanning use multithreading? Default `TRUE`
#' * `use_async`: logical: should the async scanner (performs better on
#'    high-latency/highly parallel filesystems like S3) be used? Default `FALSE`
#' * `...`: Additional arguments, currently ignored
#' @section Methods:
#' `ScannerBuilder` has the following methods:
#'
#' - `$Project(cols)`: Indicate that the scan should only return columns given
#' by `cols`, a character vector of column names
#' - `$Filter(expr)`: Filter rows by an [Expression].
#' - `$UseThreads(threads)`: logical: should the scan use multithreading?
#' The method's default input is `TRUE`, but you must call the method to enable
#' multithreading because the scanner default is `FALSE`.
#' - `$UseAsync(use_async)`: logical: should the async scanner be used?
#' - `$BatchSize(batch_size)`: integer: Maximum row count of scanned record
#' batches, default is 32K. If scanned record batches are overflowing memory
#' then this method can be called to reduce their size.
#' - `$schema`: Active binding, returns the [Schema] of the Dataset
#' - `$Finish()`: Returns a `Scanner`
#'
#' `Scanner` currently has a single method, `$ToTable()`, which evaluates the
#' query and returns an Arrow [Table].
#' @rdname Scanner
#' @name Scanner
#' @export
Scanner <- R6Class("Scanner",
  inherit = ArrowObject,
  public = list(
    ToTable = function() dataset___Scanner__ToTable(self),
    ScanBatches = function() dataset___Scanner__ScanBatches(self),
    ToRecordBatchReader = function() dataset___Scanner__ToRecordBatchReader(self),
    CountRows = function() dataset___Scanner__CountRows(self)
  ),
  active = list(
    schema = function() dataset___Scanner__schema(self)
  )
)
Scanner$create <- function(dataset,
                           projection = NULL,
                           filter = TRUE,
                           use_threads = option_use_threads(),
                           use_async = getOption("arrow.use_async", FALSE),
                           batch_size = NULL,
                           fragment_scan_options = NULL,
                           ...) {
  if (inherits(dataset, "arrow_dplyr_query")) {
    if (is_collapsed(dataset)) {
      # TODO: Is there a way to get a RecordBatchReader rather than evaluating?
      dataset$.data <- as_adq(dplyr::compute(dataset$.data))$.data
    }

    proj <- c(dataset$selected_columns, dataset$temp_columns)

    if (!is.null(projection)) {
      if (is.character(projection)) {
        stopifnot("attempting to project with unknown columns" = all(projection %in% names(proj)))
        proj <- proj[projection]
      } else {
        # TODO: ARROW-13802 accepting lists of Expressions as a projection
        warning(
          "Scanner$create(projection = ...) must be a character vector, ",
          "ignoring the projection argument."
        )
      }
    }

    if (!isTRUE(filter)) {
      dataset <- set_filters(dataset, filter)
    }

    return(Scanner$create(
      dataset$.data,
      proj,
      dataset$filtered_rows,
      use_threads,
      use_async,
      batch_size,
      fragment_scan_options,
      ...
    ))
  }
  if (inherits(dataset, c("data.frame", "ArrowTabular"))) {
    dataset <- InMemoryDataset$create(dataset)
  }
  assert_is(dataset, "Dataset")

  scanner_builder <- dataset$NewScan()
  if (use_threads) {
    scanner_builder$UseThreads()
  }
  if (use_async) {
    scanner_builder$UseAsync()
  }
  if (!is.null(projection)) {
    scanner_builder$Project(projection)
  }
  if (!isTRUE(filter)) {
    scanner_builder$Filter(filter)
  }
  if (is_integerish(batch_size)) {
    scanner_builder$BatchSize(batch_size)
  }
  if (!is.null(fragment_scan_options)) {
    scanner_builder$FragmentScanOptions(fragment_scan_options)
  }
  scanner_builder$Finish()
}

#' @export
names.Scanner <- function(x) names(x$schema)

ScanTask <- R6Class("ScanTask",
  inherit = ArrowObject,
  public = list(
    Execute = function() dataset___ScanTask__get_batches(self)
  )
)

#' Apply a function to a stream of RecordBatches
#'
#' As an alternative to calling `collect()` on a `Dataset` query, you can
#' use this function to access the stream of `RecordBatch`es in the `Dataset`.
#' This lets you aggregate on each chunk and pull the intermediate results into
#' a `data.frame` for further aggregation, even if you couldn't fit the whole
#' `Dataset` result in memory.
#'
#' This is experimental and not recommended for production use.
#'
#' @param X A `Dataset` or `arrow_dplyr_query` object, as returned by the
#' `dplyr` methods on `Dataset`.
#' @param FUN A function or `purrr`-style lambda expression to apply to each
#' batch
#' @param ... Additional arguments passed to `FUN`
#' @param .data.frame logical: collect the resulting chunks into a single
#' `data.frame`? Default `TRUE`
#' @export
map_batches <- function(X, FUN, ..., .data.frame = TRUE) {
  if (.data.frame) {
    lapply <- map_dfr
  }
  scanner <- Scanner$create(ensure_group_vars(X))
  FUN <- as_mapper(FUN)
  lapply(scanner$ScanBatches(), function(batch) {
    # TODO: wrap batch in arrow_dplyr_query with X$selected_columns,
    # X$temp_columns, and X$group_by_vars
    # if X is arrow_dplyr_query, if some other arg (.dplyr?) == TRUE
    FUN(batch, ...)
  })
}

#' @usage NULL
#' @format NULL
#' @rdname Scanner
#' @export
ScannerBuilder <- R6Class("ScannerBuilder",
  inherit = ArrowObject,
  public = list(
    Project = function(cols) {
      # cols is either a character vector or a named list of Expressions
      if (is.character(cols)) {
        dataset___ScannerBuilder__ProjectNames(self, cols)
      } else if (length(cols) == 0) {
        # Empty projection
        dataset___ScannerBuilder__ProjectNames(self, character(0))
      } else {
        # List of Expressions
        dataset___ScannerBuilder__ProjectExprs(self, cols, names(cols))
      }
      self
    },
    Filter = function(expr) {
      assert_is(expr, "Expression")
      dataset___ScannerBuilder__Filter(self, expr)
      self
    },
    UseThreads = function(threads = option_use_threads()) {
      dataset___ScannerBuilder__UseThreads(self, threads)
      self
    },
    UseAsync = function(use_async = TRUE) {
      dataset___ScannerBuilder__UseAsync(self, use_async)
      self
    },
    BatchSize = function(batch_size) {
      dataset___ScannerBuilder__BatchSize(self, batch_size)
      self
    },
    FragmentScanOptions = function(options) {
      dataset___ScannerBuilder__FragmentScanOptions(self, options)
      self
    },
    Finish = function() dataset___ScannerBuilder__Finish(self)
  ),
  active = list(
    schema = function() dataset___ScannerBuilder__schema(self)
  )
)

#' @export
names.ScannerBuilder <- function(x) names(x$schema)
