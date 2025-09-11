import directories
import filepath as path
import gleam/bool
import gleam/dynamic/decode
import gleam/http/request
import gleam/http/response
import gleam/httpc
import gleam/json
import gleam/list
import gleam/option
import gleam/result
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
  Pack(pack_directory: String, packages: List(Package))
}

pub type LoadError {
  FailedToGetDirectory
  FailedToCreateDirectory(file.FileError)
  FailedToWriteToFile(file.FileError)
  FailedToWriteReadFile(file.FileError)
  RequestFailed(url: String, error: httpc.HttpError)
  RequestReturnedIncorrectResponse(status_code: Int)
  ResponseJsonInvalid(json.DecodeError)
  FileContainedInvalidJson(json.DecodeError)
  FailedToDecodeHexTarball
}

pub fn load() -> Result(Pack, LoadError) {
  use data_directory <- result.try(result.replace_error(
    directories.data_local_dir(),
    FailedToGetDirectory,
  ))
  let pack_directory = pack_directory(data_directory)

  use <- bool.lazy_guard(
    file.is_file(packages_file(pack_directory)) == Ok(True),
    fn() { load_pack_from_file(pack_directory) },
  )

  use packages <- result.try(fetch_packages())

  let pack = Pack(pack_directory:, packages:)

  use Nil <- result.try(write_to_file(pack))

  Ok(pack)
}

fn load_pack_from_file(pack_directory: String) -> Result(Pack, LoadError) {
  let file_path = packages_file(pack_directory)

  use json <- result.try(result.map_error(
    file.read(file_path),
    FailedToWriteReadFile,
  ))

  use packages <- result.try(result.map_error(
    json.parse(json, decode.at(["packages"], decode.list(package_decoder()))),
    FileContainedInvalidJson,
  ))

  Ok(Pack(pack_directory:, packages:))
}

const packages_api_url = "https://packages.gleam.run/api/packages/"

fn fetch_packages() -> Result(List(Package), LoadError) {
  let assert Ok(request) = request.to(packages_api_url)
    as "URL parsing should always succeed"

  use response <- result.try(
    httpc.send(request) |> result.map_error(RequestFailed(packages_api_url, _)),
  )

  use Nil <- result.try(check_response_status(response))

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

  list.try_map(package_names, fetch_package)
}

fn fetch_package(name: String) -> Result(Package, LoadError) {
  let url = packages_api_url <> name
  let assert Ok(request) = request.to(url)
    as "URL parsing should always succeed"
  use response <- result.try(
    httpc.send(request) |> result.map_error(RequestFailed(url, _)),
  )

  use Nil <- result.try(check_response_status(response))

  result.map_error(
    json.parse(response.body, decode.at(["data"], package_decoder())),
    ResponseJsonInvalid,
  )
}

fn check_response_status(
  response: response.Response(a),
) -> Result(Nil, LoadError) {
  case response.status {
    200 -> Ok(Nil)
    status -> Error(RequestReturnedIncorrectResponse(status_code: status))
  }
}

fn pack_directory(data_directory: String) -> String {
  path.join(data_directory, "pack")
}

pub fn packages_directory(pack: Pack) -> String {
  path.join(pack.pack_directory, "packages")
}

fn write_to_file(pack: Pack) -> Result(Nil, LoadError) {
  let json =
    json.object([#("packages", json.array(pack.packages, package_to_json))])
    |> json.to_string

  use Nil <- result.try(result.map_error(
    file.create_directory_all(pack.pack_directory),
    FailedToCreateDirectory,
  ))

  result.map_error(
    file.write(json, to: packages_file(pack.pack_directory)),
    FailedToWriteToFile,
  )
}

fn packages_file(pack_directory: String) -> String {
  path.join(pack_directory, "packages.json")
}

pub fn main() -> Nil {
  let assert Ok(pack) = load()
  let assert Ok(Nil) = download_packages(pack)
  Nil
}

const hex_tarballs_url = "https://repo.hex.pm/tarballs/"

pub fn download_packages(pack: Pack) -> Result(Nil, LoadError) {
  let packages_directory = packages_directory(pack)

  use package <- list.try_each(pack.packages)

  let directory_path = path.join(packages_directory, package.name)

  // If the directory already exists, that means the package is already downloaded,
  // so we can skip it.
  use <- bool.guard(file.is_directory(directory_path) == Ok(True), Ok(Nil))

  let file_name = package.name <> "-" <> package.latest_version <> ".tar"

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
  use <- bool.guard(response.status == 404, Ok(Nil))

  // TODO: Maybe skip all failed requests but log them somehow?
  use Nil <- result.try(check_response_status(response))

  use files <- result.try(result.replace_error(
    extract_files(response.body),
    FailedToDecodeHexTarball,
  ))

  list.try_each(files, fn(file) {
    let #(name, contents) = file
    let path = path.join(directory_path, name)
    let containing_directory = path.directory_name(path)

    use Nil <- result.try(result.map_error(
      file.create_directory_all(containing_directory),
      FailedToCreateDirectory,
    ))

    file.write_bits(contents, to: path)
    |> result.map_error(FailedToWriteToFile)
  })
}

@external(erlang, "pack_ffi", "extract_files")
fn extract_files(bits: BitArray) -> Result(List(#(String, BitArray)), Nil)
