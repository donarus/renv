
# tools for querying information about packages available on CRAN.
# note that this does _not_ merge package entries from multiple repositories;
# rather, a list of databases is returned (one for each repository)
renv_available_packages <- function(type, limit = NULL, quiet = FALSE) {

  limit <- limit %||% Sys.getenv("R_AVAILABLE_PACKAGES_CACHE_CONTROL_MAX_AGE", "3600")

  # force a CRAN mirror when needed
  repos <- getOption("repos") %||% character()
  repos[repos == "@CRAN@"] <- "https://cloud.r-project.org"
  options(repos = convert(repos, "character"))

  renv_timecache(
    list(repos = getOption("repos"), type = type),
    renv_available_packages_impl(type, quiet),
    limit = as.integer(limit),
    timeout = renv_available_packages_timeout
  )
}

renv_available_packages_impl <- function(type, quiet = FALSE) {

  if (quiet)
    renv_scope_options(renv.verbose = FALSE)

  fmt <- "* Querying repositories for available %s packages ... "
  vprintf(fmt, type)

  # request repositories
  repos <- getOption("repos")
  urls <- contrib.url(repos, type)
  dbs <- lapply(urls, renv_available_packages_query, type = type)
  names(dbs) <- names(repos)

  # notify finished
  vwritef("Done!")

  # and we're done
  dbs

}

renv_available_packages_query <- function(url, type) {

  # check for a cached value
  name <- sprintf("repos_%s.rds.cache", URLencode(url, reserved = TRUE))
  path <- file.path(tempdir(), name)
  if (file.exists(path)) {
    db <- readRDS(path)
    unlink(path)
    return(as.data.frame(db, stringsAsFactors = FALSE))
  }

  # make the query (suppress warnings in case this is a local repository
  # whose PACKAGES files do not exist; note that an error is thrown in that
  # case anyhow)
  db <- withCallingHandlers(
    catch(available.packages(contriburl = url)),
    warning = function(w) invokeRestart("muffleWarning"),
    message = function(m) invokeRestart("muffleMessage")
  )

  # report errors
  if (inherits(db, "error")) {
    vwritef("FAILED")
    return(data.frame())
  }

  # return the db
  as.data.frame(db, stringsAsFactors = FALSE)

}

renv_available_packages_entry <- function(package,
                                          type,
                                          repos = NULL,
                                          filter = NULL,
                                          quiet = FALSE)
{
  filter <- filter %||% function(entry) TRUE
  if (is.character(filter)) {
    version <- filter
    filter <- function(entry) entry$Version == version
  }

  dbs <- renv_available_packages(type = type, quiet = quiet)

  repos <- repos %||% names(dbs)
  dbs <- dbs[repos]

  for (i in seq_along(dbs)) {

    db <- dbs[[i]]
    if (!package %in% db$Package)
      next

    entry <- db[package, ]
    if (filter(entry)) {
      entry[["Type"]] <- type
      entry[["Name"]] <- names(dbs)[[i]] %||% ""
      return(entry)
    }

  }

  stopf("failed to find %s for package %s in active repositories", type, package)
}

renv_available_packages_timeout <- function(data) {
  urls <- contrib.url(data$repos, data$type)
  for (url in urls) {
    name <- sprintf("repos_%s.rds", URLencode(url, reserved = TRUE))
    path <- file.path(tempdir(), name)
    unlink(path)
  }
}

renv_available_packages_record <- function(entry, type) {

  record <- list(
    Package    = entry$Package,
    Version    = entry$Version,
    Source     = "Repository",
    Repository = entry$Name
  )

  attr(record, "type") <- type
  attr(record, "url")  <- entry$Repository

  record

}

renv_available_packages_latest_impl <- function(package, type) {

  dbs <- renv_available_packages(type = type, quiet = TRUE)
  fields <- c("Package", "Version", "NeedsCompilation", "Repository")
  entries <- bapply(dbs, function(db) {
    db[db$Package == package, fields]
  }, index = "Name")

  if (is.null(entries))
    return(NULL)

  version <- numeric_version(entries$Version)
  ordered <- order(version, decreasing = TRUE)
  entries[ordered[[1]], , drop = FALSE]

}

renv_available_packages_latest <- function(package) {

  # if we're not using binary repositories,
  # then just take the latest available from source repositories
  types <- renv_package_pkgtypes()
  if (!"binary" %in% types) {

    entry <- renv_available_packages_latest_impl(package, "source")
    if (is.null(entry))
      stopf("package '%s' is not available", package)

    record <- renv_available_packages_record(entry, "source")
    return(record)

  }

  # get latest source, binary packages available
  src <- renv_available_packages_latest_impl(package, "source")
  bin <- renv_available_packages_latest_impl(package, "binary")

  # choose an appropriate record
  if (is.null(src) && is.null(bin))
    stopf("package '%s' is not available", package)
  else if (is.null(src))
    renv_available_packages_record(bin, "binary")
  else if (is.null(bin))
    renv_available_packages_record(src, "source")
  else
    renv_available_packages_latest_select(src, bin)

}

renv_available_packages_latest_select <- function(src, bin) {

  # if the binary is at least as old as the source version,
  # then use the binary version
  if (version_compare(bin$Version, src$Version) >= 0)
    return(renv_available_packages_record(bin, "binary"))

  # if the user has requested we skip source repositories,
  # use the binary anyway
  ipcs <- getOption("install.packages.check.source", default = "yes")
  if (!identical(ipcs, "yes"))
    return(renv_available_packages_record(bin, "binary"))

  # if the package requires compilation, check to see whether
  # the user has opted in to compiling packages from source
  nc <- identical(src$NeedsCompilation, "yes")
  if (nc) {

    # check user preference re: compilation from source
    ipcfs <- getOption(
      "install.packages.compile.from.source",
      default = Sys.getenv("R_COMPILE_AND_INSTALL_PACKAGES")
    )

    # if make is not available, then we can't build from source
    if (!nzchar(Sys.getenv("MAKE", unset = "make")))
      ipcfs <- "never"

    if (identical(ipcfs, "never"))
      return(renv_available_packages_record(bin, "binary"))

  }

  # take the source version
  renv_available_packages_record(src, "source")

}