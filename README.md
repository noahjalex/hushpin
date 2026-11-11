# Hushpin

A macOS tool that records system audio and your mic (following whichever input mic is active), mixes the recordings with ffmpeg, and transcribes them with whisper-cpp models.

## setup

You'll need:
* macOS 15+
* [Xcode](https://developer.apple.com/xcode/) (open it once to finish setup)
* [Homebrew](https://brew.sh)

1. Install the tools:

   ```sh
   brew install ffmpeg whisper.cpp zig@0.16
   ```

2. From the hushpin folder, build it and link the binary into `~/.local/bin`:

   ```sh
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer "$(brew --prefix zig@0.16)/bin/zig" build
   mkdir -p "$HOME/.local/bin"
   ln -s "$PWD/zig-out/Hushpin.app/Contents/MacOS/hushpin" "$HOME/.local/bin/hushpin"
   ```

   Don't move the hushpin folder afterward, the link points into it. If `~/.local/bin` isn't on your PATH, add it (for macOS's default shell, zsh):

   ```sh
   echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.zshrc"
   source "$HOME/.zshrc"
   ```

3. Download the English models (`tiny.en` for live text, `base.en` for the full transcript; about 220 MiB):

   ```sh
   mkdir -p "$HOME/.local/share/whisper.cpp"
   for model in tiny.en base.en; do
     curl --fail --location --retry 3 \
       "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-$model.bin" \
       --output "$HOME/.local/share/whisper.cpp/ggml-$model.bin" || break
   done
   ```

4. The first time you record, let macOS access your mic and record system audio. If recording doesn't start, check **System Settings > Privacy & Security > Microphone / Screen & System Audio Recording**, then try again

Recordings and transcripts live in `~/.local/share/hushpin`. Set `HUSHPIN_DATA_DIR` to put them somewhere else.

## commands

```sh
hushpin record                         # record; press Return or Ctrl-C to stop
hushpin record --live                  # also transcribe as you go; text may have mistakes
hushpin record --live --chunk-seconds 5 --live-model /path/to/model.bin # set chunk length and model
hushpin capture 10                     # record for 10 seconds
hushpin list                           # show recordings and their numbers
hushpin watch -s 1 --json              # follow recording 1's status as JSON; doesn't record
hushpin finish -s 1                    # mix recording 1 and save a full transcript
hushpin finish -s 1 transcript.txt --model /path/to/model.bin # use another model and save a copy here
hushpin mix -s 1                       # mix recording 1 into its audio/mixed.m4a
hushpin mix -s 1 output.m4a            # save the mix to a file here instead
hushpin transcribe -s 1               # transcribe recording 1's already-mixed audio
hushpin transcribe -s 1 text.txt --model /path/to/model.bin # use another model and output file
hushpin mix mic.caf system.caf out.m4a # mix two files; optional fourth argument: mic offset in ns
hushpin transcribe audio.m4a /path/to/model.bin text.txt # transcribe an audio file
hushpin cleanup -s 1                  # delete recording 1's audio, keeping the text
```

`-s 1` picks recording 1 from `hushpin list`; numbers change when you add recordings. Commands that take `-s N` also accept a recording ID (`recording-…`) or its folder path. Output filenames are relative to your current folder.
