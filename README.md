# Pack

A tool for downloading Gleam packages!

[![Package Version](https://img.shields.io/hexpm/v/pack)](https://hex.pm/packages/pack)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/pack/)

Pack is a tool for downloading Gleam packages using the [Gleam package index](
https://packages.gleam.run) and [Hex](https://hex.pm).

## As a CLI tool

Pack can be used as a standalone CLI tool. Either clone the repository, or download
the latest escript build from the [releases page](https://github.com/GearsDatapacks/pack/releases/latest).

Running `pack download` will download all Gleam packages from Hex to your disc,
or you can use `pack fetch` to simply fetch data from the package index without
downloading any code.

Run `pack help` for a detailed description of commands and flags.

## As a library

Pack is somewhat of an unconventional library, as it includes side-effect producing
code, including HTTP requests and writing files to disc. However, it can be useful
for applications which need to process a large set of Gleam packages, for example
[search](https://github.com/GearsDatapacks/search).

Here's some example code using `pack` as a library:

```gleam
import gleam/io
import pack

pub fn main() {
  let assert Ok(pack) = pack.load(pack.default_options)
  let assert Ok(packages) = pack.download(pack)

  dict.each(packages, fn(name, files) {
    let list_of_files =
      files
      |> list.map(fn(file) { file.name })
      |> string.join(", ")
    io.println(
      "Package " <> name <> " has the following files: " <> list_of_files,
    )
  })
}
```
