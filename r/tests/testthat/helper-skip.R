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

build_features <- c(
  arrow_info()$capabilities,
  # Special handling for "uncompressed", for tests that iterate over compressions
  uncompressed = TRUE
)

skip_if_not_available <- function(feature) {
  if (feature == "re2") {
    # RE2 does not support valgrind (on purpose): https://github.com/google/re2/issues/177
    skip_on_valgrind()
  } else if (feature == "dataset") {
    # These tests often hang on 32-bit windows rtools35, and we haven't been
    # able to figure out how to make them work safely
    skip_if_multithreading_disabled()
  }

  yes <- feature %in% names(build_features) && build_features[feature]
  if (!yes) {
    skip(paste("Arrow C++ not built with", feature))
  }
}

skip_if_no_pyarrow <- function() {
  skip_on_valgrind()
  skip_on_os("windows")

  skip_if_not_installed("reticulate")
  if (!reticulate::py_module_available("pyarrow")) {
    skip("pyarrow not available for testing")
  }
}

skip_if_not_dev_mode <- function() {
  skip_if_not(
    identical(tolower(Sys.getenv("ARROW_R_DEV")), "true"),
    "environment variable ARROW_R_DEV"
  )
}

skip_if_not_running_large_memory_tests <- function() {
  skip_if_not(
    identical(tolower(Sys.getenv("ARROW_LARGE_MEMORY_TESTS")), "true"),
    "environment variable ARROW_LARGE_MEMORY_TESTS"
  )
}

skip_on_valgrind <- function() {
  # This does not actually skip on valgrind because we can't exactly detect it.
  # Instead, it skips on CRAN when the OS is linux + and the R version is development
  # (which is where valgrind is run as of this code)
  linux_dev <- identical(tolower(Sys.info()[["sysname"]]), "linux") &&
    grepl("devel", R.version.string)

  if (linux_dev) {
    skip_on_cran()
  }
}

skip_if_multithreading_disabled <- function() {
  is_32bit <- .Machine$sizeof.pointer < 8
  is_old_r <- getRversion() < "4.0.0"
  is_windows <- tolower(Sys.info()[["sysname"]]) == "windows"
  if (is_32bit && is_old_r && is_windows) {
    skip("Multithreading does not work properly on this system")
  }
}

process_is_running <- function(x) {
  cmd <- sprintf("ps aux | grep '%s' | grep -v grep", x)
  tryCatch(system(cmd, ignore.stdout = TRUE) == 0, error = function(e) FALSE)
}
