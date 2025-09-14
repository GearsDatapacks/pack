import argv
import directories
import filepath as path
import gleam/bit_array
import gleam/bool
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/http/request
import gleam/http/response
import gleam/httpc
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import simplifile as file

pub type Package {
  Package(
    name: String,
    description: String,
    latest_version: String,
    repository: option.Option(String),
    updated_at: Int,
    releases: List(Release),
  )
}

fn package_to_json(package: Package) -> json.Json {
  let Package(
    name:,
    description:,
    latest_version:,
    repository:,
    updated_at:,
    releases:,
  ) = package
  json.object([
    #("name", json.string(name)),
    #("description", json.string(description)),
    #("latest-version", json.string(latest_version)),
    #("repository", case repository {
      option.None -> json.null()
      option.Some(value) -> json.string(value)
    }),
    #("updated-at", json.int(updated_at)),
    #("releases", json.array(releases, release_to_json)),
  ])
}

fn package_decoder() -> decode.Decoder(Package) {
  use name <- decode.field("name", decode.string)
  use description <- decode.field("description", decode.string)
  use latest_version <- decode.field("latest-version", decode.string)
  use repository <- decode.field("repository", decode.optional(decode.string))
  use updated_at <- decode.field("updated-at", decode.int)
  use releases <- decode.field("releases", decode.list(release_decoder()))
  decode.success(Package(
    name:,
    description:,
    latest_version:,
    repository:,
    updated_at:,
    releases:,
  ))
}

pub type Release {
  Release(version: String, downloads: Int, updated_at: Int)
}

fn release_to_json(release: Release) -> json.Json {
  let Release(version:, downloads:, updated_at:) = release
  json.object([
    #("version", json.string(version)),
    #("downloads", json.int(downloads)),
    #("updated-at", json.int(updated_at)),
  ])
}

fn release_decoder() -> decode.Decoder(Release) {
  use version <- decode.field("version", decode.string)
  use downloads <- decode.field("downloads", decode.int)
  use updated_at <- decode.field("updated-at", decode.int)
  decode.success(Release(version:, downloads:, updated_at:))
}

pub opaque type Pack {
  Pack(pack_directory: String, options: Options, packages: List(Package))
}

pub type Error {
  FailedToGetDirectory
  FailedToCreateDirectory(path: String, error: file.FileError)
  FailedToWriteToFile(path: String, error: file.FileError)
  FailedToReadFile(path: String, error: file.FileError)
  FailedToDeleteDirectory(path: String, error: file.FileError)
  FailedToReadDirectory(path: String, error: file.FileError)
  RequestFailed(url: String, error: httpc.HttpError)
  RequestReturnedIncorrectResponse(url: String, status_code: Int)
  ResponseJsonInvalid(json.DecodeError)
  FileContainedInvalidJson(json.DecodeError)
  FailedToDecodeHexTarball
}

pub fn describe_error(error: Error) -> String {
  case error {
    FailedToCreateDirectory(path:, error:) ->
      "Failed to create directory "
      <> path
      <> ". The error message was: "
      <> file.describe_error(error)
    FailedToDeleteDirectory(path:, error:) ->
      "Failed to delete "
      <> path
      <> ". The error message was: "
      <> file.describe_error(error)
    FailedToReadDirectory(path:, error:) ->
      "Failed to read directory "
      <> path
      <> ". The error message was: "
      <> file.describe_error(error)
    FailedToReadFile(path:, error:) ->
      "Failed to read "
      <> path
      <> ". The error message was: "
      <> file.describe_error(error)
    FailedToWriteToFile(path:, error:) ->
      "Failed to write to "
      <> path
      <> ". The error message was: "
      <> file.describe_error(error)
    FailedToDecodeHexTarball -> "Failed to decode Hex tarball"
    FailedToGetDirectory -> "Failed to find suitable directory for storing data"
    FileContainedInvalidJson(error) ->
      "Data file contained invalid JSON. The error message was: "
      <> json_error(error)
    RequestFailed(url:, error:) ->
      "Request to " <> url <> " failed. The error was: " <> httpc_error(error)
    RequestReturnedIncorrectResponse(url:, status_code:) ->
      "Request to "
      <> url
      <> " return invalid response, status code "
      <> int.to_string(status_code)
    ResponseJsonInvalid(error) -> "Response JSON invalid: " <> json_error(error)
  }
}

fn httpc_error(error: httpc.HttpError) -> String {
  case error {
    httpc.FailedToConnect(ip4:, ip6: _) ->
      "Failed to connect: " <> connect_error(ip4)
    httpc.InvalidUtf8Response -> "Invalid Utf-8 response"
    httpc.ResponseTimeout -> "Response timed out"
  }
}

fn connect_error(error: httpc.ConnectError) -> String {
  case error {
    httpc.Posix(code:) -> "Posix error: " <> code
    httpc.TlsAlert(code:, detail:) -> "TLS alert: " <> code <> ", " <> detail
  }
}

fn json_error(error: json.DecodeError) -> String {
  case error {
    json.UnableToDecode(errors) ->
      "Unable to decode: " <> string.join(list.map(errors, decode_error), "; ")
    json.UnexpectedByte(byte) -> "Unexpected byte `" <> byte <> "`"
    json.UnexpectedEndOfInput -> "Unexpected end of input"
    json.UnexpectedSequence(byte) -> "Unexpected sequence: `" <> byte <> "`"
  }
}

fn decode_error(error: decode.DecodeError) -> String {
  let decode.DecodeError(expected:, found:, path:) = error
  "Expected "
  <> expected
  <> " at "
  <> string.join(path, ".")
  <> ", but found "
  <> found
}

pub type Options {
  Options(
    write_to_file: Bool,
    refresh_package_list: Bool,
    write_packages_to_disc: Bool,
    read_packages_from_disc: Bool,
    print_logs: Bool,
  )
}

pub const default_options = Options(
  write_to_file: True,
  refresh_package_list: False,
  write_packages_to_disc: True,
  read_packages_from_disc: True,
  print_logs: True,
)

pub fn packages(pack: Pack) -> List(Package) {
  pack.packages
}

pub fn load(options: Options) -> Result(Pack, Error) {
  use pack_directory <- result.try(pack_directory())

  use <- bool.lazy_guard(
    !options.refresh_package_list
      && file.is_file(packages_file(pack_directory)) == Ok(True),
    fn() { load_pack_from_file(pack_directory, options) },
  )

  use packages <- result.try(fetch_packages(options))

  let pack = Pack(pack_directory:, packages:, options:)

  use Nil <- result.try(write_to_file(pack))

  Ok(pack)
}

fn load_pack_from_file(
  pack_directory: String,
  options: Options,
) -> Result(Pack, Error) {
  do_log(options, "Reading packages file...")
  let file_path = packages_file(pack_directory)

  use json <- result.try(
    result.map_error(file.read(file_path), FailedToReadFile(file_path, _)),
  )

  use packages <- result.try(result.map_error(
    json.parse(json, decode.at(["packages"], decode.list(package_decoder()))),
    FileContainedInvalidJson,
  ))
  do_log(options, " Done\n")

  Ok(Pack(pack_directory:, packages:, options:))
}

const packages_api_url = "https://packages.gleam.run/api/packages/"

fn fetch_packages(options: Options) -> Result(List(Package), Error) {
  do_log(options, "Fetching package list...")

  let assert Ok(request) = request.to(packages_api_url)
    as "URL parsing should always succeed"

  use response <- result.try(
    httpc.send(request) |> result.map_error(RequestFailed(packages_api_url, _)),
  )

  use Nil <- result.try(check_response_status(packages_api_url, response))

  // To get full package information, we need to send a request for each individual
  // package, so we can ignore all the data except the name here.
  let parsed_json =
    json.parse(
      response.body,
      decode.at(["data"], decode.list(decode.at(["name"], decode.string))),
    )
  use package_names <- result.try(result.map_error(
    parsed_json,
    ResponseJsonInvalid,
  ))

  do_log(options, " Done\n")

  let package_count = int.to_string(list.length(package_names))

  index_try_map(package_names, fn(package, index) {
    fetch_package(package, index, options, package_count)
  })
}

fn index_try_map(
  list: List(element),
  f: fn(element, Int) -> Result(result, error),
) -> Result(List(result), error) {
  do_index_try_map(list, 0, f, [])
}

fn do_index_try_map(
  list: List(element),
  index: Int,
  f: fn(element, Int) -> Result(result, error),
  acc: List(result),
) -> Result(List(result), error) {
  case list {
    [] -> Ok(list.reverse(acc))
    [first, ..rest] ->
      case f(first, index) {
        Error(error) -> Error(error)
        Ok(value) -> do_index_try_map(rest, index + 1, f, [value, ..acc])
      }
  }
}

fn fetch_package(
  name: String,
  index: Int,
  options: Options,
  total_packages: String,
) -> Result(Package, Error) {
  do_log(options, "Fetching information for " <> name <> "...")

  let url = packages_api_url <> name
  let assert Ok(request) = request.to(url)
    as "URL parsing should always succeed"
  use response <- result.try(
    httpc.send(request) |> result.map_error(RequestFailed(url, _)),
  )

  use Nil <- result.try(check_response_status(url, response))

  use package <- result.map(result.map_error(
    json.parse(response.body, decode.at(["data"], package_decoder())),
    ResponseJsonInvalid,
  ))

  do_log(
    options,
    " Done (" <> int.to_string(index + 1) <> "/" <> total_packages <> ")\n",
  )

  package
}

fn check_response_status(
  url: String,
  response: response.Response(a),
) -> Result(Nil, Error) {
  case response.status {
    200 -> Ok(Nil)
    status -> Error(RequestReturnedIncorrectResponse(url:, status_code: status))
  }
}

fn pack_directory() -> Result(String, Error) {
  result.map(
    result.replace_error(directories.data_local_dir(), FailedToGetDirectory),
    path.join(_, "pack"),
  )
}

pub fn packages_directory(pack: Pack) -> String {
  path.join(pack.pack_directory, "packages")
}

fn write_to_file(pack: Pack) -> Result(Nil, Error) {
  log(pack, "Writing packages to file...")

  let json =
    json.object([#("packages", json.array(pack.packages, package_to_json))])
    |> json.to_string

  use Nil <- result.try(
    result.map_error(
      file.create_directory_all(pack.pack_directory),
      FailedToCreateDirectory(pack.pack_directory, _),
    ),
  )

  let packages_file = packages_file(pack.pack_directory)
  use Nil <- result.map(
    result.map_error(file.write(json, to: packages_file), FailedToWriteToFile(
      packages_file,
      _,
    )),
  )

  log(pack, " Done\n")
}

fn packages_file(pack_directory: String) -> String {
  path.join(pack_directory, "packages.json")
}

type Command {
  Help
  Fetch(options: Options)
  Download(options: Options)
  Directory
}

pub fn main() -> Nil {
  let arguments = argv.load().arguments

  let command = parse_arguments(arguments)

  case command {
    Help -> print_help()
    Download(options:) -> {
      let assert Ok(pack) = load(options)
      let assert Ok(Nil) = download_packages_to_disc(pack)
      Nil
    }
    Fetch(options:) -> {
      let assert Ok(_) = load(options)
      Nil
    }
    Directory -> {
      let assert Ok(directory) = pack_directory()
      io.println("Pack files are stored in " <> directory)
    }
  }
}

fn parse_arguments(arguments: List(String)) -> Command {
  case arguments {
    ["download", ..arguments] ->
      Download(parse_options(arguments, default_options))
    ["fetch", ..arguments] -> Fetch(parse_options(arguments, default_options))
    ["directory", ..] -> Directory
    _ -> Help
  }
}

fn parse_options(arguments: List(String), options: Options) -> Options {
  case arguments {
    [] -> options
    ["--refresh", ..arguments] ->
      parse_options(arguments, Options(..options, refresh_package_list: True))
    ["--redownload-all", ..arguments] ->
      parse_options(
        arguments,
        Options(..options, read_packages_from_disc: False),
      )
    [_, ..arguments] -> parse_options(arguments, options)
  }
}

fn print_help() -> Nil {
  io.println(
    "
USAGE: pack <command> [flags]

Commands:
- help: Print this help message
- fetch: Fetch package information from the Gleam package index without downloading
  any source code
- download: Download all Gleam packages from Hex
- directory: Print the directory `pack` uses to store data

Flags:

--refresh  If `pack` has been run before, the information from the Gleam package
  index is cached in a file to avoid querying the API every time. `--refresh`
  causes `pack` to re-fetch all information from the package index.

--redownload-all  Normally, when downloading packages, `pack` will skip any which
  already are on disc. Instead, all packages will be re-downloaded.
",
  )
}

const hex_tarballs_url = "https://repo.hex.pm/tarballs/"

pub type File {
  TextFile(name: String, contents: String)
  BinaryFile(name: String, contents: BitArray)
}

pub fn download_packages(pack: Pack) -> Result(Dict(String, List(File)), Error) {
  use packages <- result.map(do_download_packages(pack))

  log(pack, "Extracting package files...")

  let result =
    list.fold(packages, dict.new(), fn(packages, package) {
      let #(name, files) = package

      let files =
        list.map(files, fn(file) {
          let #(name, contents) = file
          case bit_array.to_string(contents) {
            Error(_) -> BinaryFile(name:, contents:)
            Ok(contents) -> TextFile(name:, contents:)
          }
        })

      dict.insert(packages, name, files)
    })

  log(pack, " Done\n")
  result
}

fn do_download_packages(
  pack: Pack,
) -> Result(List(#(String, List(#(String, BitArray)))), Error) {
  let packages_directory = packages_directory(pack)

  let package_count = int.to_string(list.length(pack.packages))

  let result =
    list.try_fold(pack.packages, #([], 0), fn(acc, package) {
      let #(packages, index) = acc

      let directory_path = path.join(packages_directory, package.name)
      let with_slash = directory_path <> "/"

      let index = index + 1

      // If the directory already exists, that means the package is already downloaded,
      // so we can skip it.
      case file.is_directory(directory_path) {
        Ok(True) if pack.options.read_packages_from_disc -> {
          log(pack, "Reading package " <> package.name <> "from disc...")
          use files <- result.try(
            result.map_error(
              file.get_files(directory_path),
              FailedToReadDirectory(directory_path, _),
            ),
          )
          use files <- result.try(
            list.try_map(files, fn(path) {
              let name = strip_prefix(path, with_slash)

              case file.read_bits(path) {
                Error(error) -> Error(FailedToReadFile(path, error))
                Ok(contents) -> Ok(#(name, contents))
              }
            }),
          )
          log(
            pack,
            " Done (" <> int.to_string(index) <> "/" <> package_count <> ")\n",
          )
          Ok(#([#(package.name, files), ..packages], index))
        }
        Ok(True) -> {
          use Nil <- result.try(
            result.map_error(
              file.delete(directory_path),
              FailedToDeleteDirectory(directory_path, _),
            ),
          )
          case download_package(pack, package, index, package_count) {
            Ok(option.None) -> Ok(#(packages, index))
            Ok(option.Some(package)) -> Ok(#([package, ..packages], index))
            Error(error) -> Error(error)
          }
        }
        Error(_) | Ok(False) -> {
          case download_package(pack, package, index, package_count) {
            Ok(option.None) -> Ok(#(packages, index))
            Ok(option.Some(package)) -> Ok(#([package, ..packages], index))
            Error(error) -> Error(error)
          }
        }
      }
    })

  case result {
    Error(error) -> Error(error)
    Ok(#(packages, _)) -> Ok(packages)
  }
}

fn download_package(
  pack: Pack,
  package: Package,
  index: Int,
  package_count: String,
) -> Result(option.Option(#(String, List(#(String, BitArray)))), Error) {
  let file_name = package.name <> "-" <> package.latest_version <> ".tar"

  log(pack, "Downloading " <> file_name <> "...")

  let url = hex_tarballs_url <> file_name
  let assert Ok(request) = request.to(url) as "URL parsing failed"

  use response <- result.try(
    request
    |> request.set_body(<<>>)
    |> httpc.send_bits
    |> result.map_error(RequestFailed(url, _)),
  )

  // Sometimes the package index contains outdated information including packages
  // which don't exist on Hex anymore. In that case, we want to gracefully skip
  // non-existent packages so the rest of the downloads can proceed.
  use <- bool.lazy_guard(response.status == 404, fn() {
    log(pack, " Package missing on Hex\n")
    Ok(option.None)
  })

  // TODO: Maybe skip all failed requests but log them somehow?
  use Nil <- result.try(check_response_status(url, response))

  use files <- result.try(result.replace_error(
    extract_files(response.body),
    FailedToDecodeHexTarball,
  ))

  use Nil <- result.try(case pack.options.write_packages_to_disc {
    False -> Ok(Nil)
    True -> write_package_files_to_disc(pack, package.name, files)
  })

  log(pack, " Done (" <> int.to_string(index) <> "/" <> package_count <> ")\n")
  Ok(option.Some(#(package.name, files)))
}

pub fn download_packages_to_disc(pack: Pack) -> Result(Nil, Error) {
  do_download_packages(pack) |> result.replace(Nil)
}

fn write_package_files_to_disc(
  pack: Pack,
  package_name: String,
  files: List(#(String, BitArray)),
) -> Result(Nil, Error) {
  let packages_directory = packages_directory(pack)

  let directory_path = path.join(packages_directory, package_name)

  list.try_each(files, fn(file) {
    let #(name, contents) = file
    let path = path.join(directory_path, name)
    let containing_directory = path.directory_name(path)

    use Nil <- result.try(
      result.map_error(
        file.create_directory_all(containing_directory),
        FailedToCreateDirectory(containing_directory, _),
      ),
    )

    file.write_bits(contents, to: path)
    |> result.map_error(FailedToWriteToFile(path, _))
  })
}

fn log(pack: Pack, text: String) -> Nil {
  do_log(pack.options, text)
}

fn do_log(options: Options, text: String) -> Nil {
  case options.print_logs {
    False -> Nil
    True -> io.print(text)
  }
}

@external(erlang, "pack_ffi", "extract_files")
fn extract_files(bits: BitArray) -> Result(List(#(String, BitArray)), Nil)

@external(erlang, "pack_ffi", "strip_prefix")
fn strip_prefix(string: String, prefix: String) -> String
