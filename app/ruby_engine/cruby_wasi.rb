# await: *await*, loading

require 'await'

class RubyEngine
  class CRubyWASI < RubyEngine
    REQUIRED_SCRIPTS = [
        {
            # https://www.jsdelivr.com/package/npm/@ruby/wasm-wasi?version=2.7.1&tab=files&path=dist
            src: "https://cdn.jsdelivr.net/npm/@ruby/wasm-wasi@2.7.1/dist/browser.umd.js",
            integrity: "sha256-7BFeYf6/25URj7e1BHDr2wN2zWD0ISeSXbbLYWXNrmc=",
            crossorigin: "anonymous"
        },
        {
            src: "https://cdn.jsdelivr.net/npm/@wasmer/wasmfs@0.12.0/lib/index.iife.js",
            integrity: "sha256-sOd4ekxVsN4PXhR+cn/4uNAxeQOJRcsaW5qalYfvkTw=",
            crossorigin: "anonymous"
        },
        {
            src: "https://cdn.jsdelivr.net/npm/@wasmer/wasi@0.12.0/lib/index.iife.js",
            integrity: "sha256-FslFp/Vq4bDf2GXu+9QyBEDLtEWO3fkMjpyOaJMHJT8=",
            crossorigin: "anonymous"
        }
    ]

    def initialize(ruby_wasm_url, version)
      @ruby_wasm_url = ruby_wasm_url
      @version = version
    end

    def name
      "CRuby #{@version}"
    end

    def engine_id
      "cruby-#{@version}"
    end

    # Below functions will be compiled as async functions
    def self.inject_scripts
      @injected ||= begin
        REQUIRED_SCRIPTS.map do |script|
          promise = PromiseV2.new
          script = $document.create_element("script", attrs: script)
          script.on("load") { promise.resolve }
          script.on("error") { promise.reject(StandardError.new("failed to load #{script[:src]}")) }
          $document.head << script
          promise
        end.each_await(&:itself)
        true
      end
    end

    def wasm_module
      @module ||= begin
        response = `fetch(#{@ruby_wasm_url})`.await
        buffer = `response.arrayBuffer()`.await
        `WebAssembly.compile(buffer)`.await
      end
    end

    def run(source)
      `var $WASI, $WasmFs, $DefaultRubyVM`
      wasmInstance, wasmModule, vm, wasi, imports = nil

      loading("downloading scripts") { CRubyWASI.inject_scripts.await }

      loading("early load") do
        `$WASI = window["WASI"].WASI`
        `$WasmFs = window["WasmFs"].WasmFs`
        `$DefaultRubyVM = window["ruby-wasm-wasi"].DefaultRubyVM`

        wasmFs = `new $WasmFs()`
        originalWriteSync = `wasmFs.fs.writeSync.bind(wasmFs.fs)`
        textDecoder = `new TextDecoder("utf-8")`
        %x{
          wasmFs.fs.writeSync = (fd, buffer, offset, length, position) => {
            if (fd == 1 || fd == 2) {
              const text = textDecoder.decode(buffer);
              #{@writer.print_to_output(`text`, "")};
            }
            return originalWriteSync(fd, buffer, offset, length, position);
          };
        }

      end

      loading("downloading ruby") do
        wasmModule = wasm_module.await
      end

      loading("instantiating") do
        # vm, wasi = `$RubyDefaultVM(wasmModule, { bindings: { ...$WASI.defaultBindings, fs: wasmFs.fs } })`.await
        # wasi = `new $WASI({
        #   bindings: { ...$WASI.defaultBindings, fs: wasmFs.fs },
        # })`
        # imports = `{ wasi_snapshot_preview1: wasi.wasiImport }`
        # `vm.addToImports(imports)`
      end

    %x{
      function myPrinter() {
        let memory = undefined;
        let _view = undefined;
          function getMemoryView() {
              if (typeof memory === "undefined") {
                  throw new Error("Memory is not set");
              }
              if (_view === undefined || _view.buffer.byteLength === 0) {
                  _view = new DataView(memory.buffer);
              }
              return _view;
          }
          const decoder = new TextDecoder();
          return {
              addToImports(imports) {
                  const wasiImport = imports.wasi_snapshot_preview1;
                  const original_fd_write = wasiImport.fd_write;
                  wasiImport.fd_write = (fd, iovs, iovsLen, nwritten) => {
                      if (fd !== 1 && fd !== 2) {
                          return original_fd_write(fd, iovs, iovsLen, nwritten);
                      }
                      const view = getMemoryView();
                      const buffers = Array.from({ length: iovsLen }, (_, i) => {
                          const ptr = iovs + i * 8;
                          const buf = view.getUint32(ptr, true);
                          const bufLen = view.getUint32(ptr + 4, true);
                          return new Uint8Array(memory.buffer, buf, bufLen);
                      });
                      let written = 0;
                      let str = "";
                      for (const buffer of buffers) {
                          str += decoder.decode(buffer);
                          written += buffer.byteLength;
                      }
                      view.setUint32(nwritten, written, true);
                      #{@writer.print_to_output(`str`, "")}
                      return 0;
                  };
                  const original_fd_filestat_get = wasiImport.fd_filestat_get;
                  wasiImport.fd_filestat_get = (fd, filestat) => {
                      if (fd !== 1 && fd !== 2) {
                          return original_fd_filestat_get(fd, filestat);
                      }
                      const view = getMemoryView();
                      const result = original_fd_filestat_get(fd, filestat);
                      if (result !== 0) {
                          return result;
                      }
                      const filetypePtr = filestat + 0;
                      view.setUint8(filetypePtr, 2); // FILETYPE_CHARACTER_DEVICE
                      return 0;
                  };
                  const original_fd_fdstat_get = wasiImport.fd_fdstat_get;
                  wasiImport.fd_fdstat_get = (fd, fdstat) => {
                      if (fd !== 1 && fd !== 2) {
                          return original_fd_fdstat_get(fd, fdstat);
                      }
                      const view = getMemoryView();
                      const fs_filetypePtr = fdstat + 0;
                      view.setUint8(fs_filetypePtr, 2); // FILETYPE_CHARACTER_DEVICE
                      const fs_rights_basePtr = fdstat + 8;
                      // See https://github.com/WebAssembly/WASI/blob/v0.2.0/legacy/preview1/docs.md#record-members
                      const RIGHTS_FD_WRITE = 1 << 6;
                      view.setBigUint64(fs_rights_basePtr, BigInt(RIGHTS_FD_WRITE), true);
                      return 0;
                  };
              },
              setMemory(m) {
                  memory = m;
              },
          };
      }}
      loading("initializing") do await
        # `vm.setInstance(wasmInstance)`.await
        # `wasi.setMemory(wasmInstance.exports.memory)`
        # `vm.initialize()`
        defaultVM = `$DefaultRubyVM(wasmModule, { consolePrint: myPrinter })`.await
        vm = `defaultVM["vm"]`
        wasi = `defaultVM["wasi"]`
        wasmInstance = `defaultVM["instance"]`
        set_external_encoding = "Encoding.default_external = Encoding::UTF_8"
        `vm.eval(set_external_encoding)`
      end

      yield `vm.eval(source).toString()`
    rescue JS::Error => err
      raise err
    end

    def exception_to_string(err)
      # "...: undefined method `reverse' for 40:Integer (NoMethodError)\n (Exception)\n"
      super(err).sub(/\s+\(Exception\)\s*\z/, '')
    end
  end
end
