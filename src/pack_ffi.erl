-module(pack_ffi).

-export([extract_files/1, strip_prefix/2]).

%% Extracts all files from a Hex tarball. A Hex tarball is a `.tar` file, which
%% contains another `contents.tar.gz` gzip file, which contains the source code.
%% So we first need to decompress the `tar` file, then extract the contents of
%% `contents.tar.gz`.
extract_files(Bits) ->
    % Extract `contents.tar.gz` from the tarball
    case erl_tar:extract({binary, Bits}, [{files, ["contents.tar.gz"]}, memory]) of
        {ok, [{"contents.tar.gz", Contents}]} ->
            try
                % Unzip the compress `contents.tar.gz` file
                Data = zlib:gunzip(Contents),
                % Extract source files from the decompressed data
                case erl_tar:extract({binary, Data}, [memory]) of
                    {ok, Files = [_ | _]} ->
                        {ok, remap_files(Files, [])};
                    _ ->
                        {error, nil}
                end
            catch
                _:_:_ -> {error, nil}
            end;
        _ ->
            {error, nil}
    end.

%% Turns a `List(#(Charlist, BitArray)) into `List(#(String, BitArray))`, to make it
%% Easier for Gleam to consume.
remap_files(Files, Out) ->
    case Files of
        [] ->
            Out;
        [{Name, Contents} | Rest] ->
            remap_files(Rest, [{list_to_binary(Name), Contents} | Out])
    end.

strip_prefix(String, Prefix) ->
    Prefix_size = byte_size(Prefix),

    case Prefix =:= binary_part(String, 0, Prefix_size) of
        true ->
            String_size = byte_size(String),
            binary_part(String, Prefix_size, String_size - Prefix_size);
        false ->
            String
    end.
