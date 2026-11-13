# frozen_string_literal: true

module AxumDsl
  # `image_variant(path, filename, width, height)`: an Active Storage variant made as Rails makes it,
  # `blob.variant(resize_to_limit: [width, height], format: ...)` through ImageProcessing::Vips (image_processing 1.14):
  #
  #   new_from_file(path)                          # loader(page: 0): the first page, which is the default
  #   .autorot                                     # load_image's auto-rotation
  #   .thumbnail_image(width, height: height, size: :down, no_rotate: true)
  #   .conv(SHARPEN_MASK, precision: :integer)     # [[-1,-1,-1],[-1,32,-1],[-1,-1,-1]], scale 24
  #   .write_to_file("<tmp>.<format>")             # the saver the filename's extension picks, with its defaults
  #
  # The format is the filename's extension (png, webp, jpg/jpeg or gif), as Active Storage names a variant
  # "<base>.<format>". The value is an `Upload` (the type an `:upload` field has), so `variant.store(root)` writes it and
  # its `size`, `checksum` and `metadata` are the variant blob's columns; the metadata is what Rails' analyzer writes for
  # it (identified, the variant's width and height, analyzed). It is nil when the image cannot be read or written, or
  # when libvips (libvips.so.42) is not installed: the library is opened at run time, so building needs no libvips.
  #
  # Against the same libvips (8.16.1, Debian 13's), the bytes are Rails' byte for byte: the fuzz run in campfire_axum_dsl's
  # test/differential/fuzz_image_variant matched 1,000 of 1,000 random PNG, JPEG (EXIF-rotated too), GIF and WebP images
  # at three limits and four output formats.
  module ImageVariant
    module_function

    CALL = "image_variant"

    def used?(ir) = ir["builtins"].to_a.include?(CALL)

    def items(ir) = used?(ir) ? RUNTIME.lines.map(&:chomp) + [""] : []

    def deps(ir) = used?(ir) ? "\nlibloading = \"0.8\"" : ""

    RUNTIME = <<~'RS'
      // image_variant (lib/axum_dsl/image_variant.rb): libvips through its C API, opened at run time.
      type AxumDslVipsImage = *mut ::std::ffi::c_void;

      struct AxumDslVips {
          _library: ::libloading::Library,
          new_from_file: unsafe extern "C" fn(*const ::std::ffi::c_char, ...) -> AxumDslVipsImage,
          autorot: unsafe extern "C" fn(AxumDslVipsImage, *mut AxumDslVipsImage, ...) -> ::std::ffi::c_int,
          thumbnail_image: unsafe extern "C" fn(AxumDslVipsImage, *mut AxumDslVipsImage, ::std::ffi::c_int, ...) -> ::std::ffi::c_int,
          matrix: unsafe extern "C" fn(::std::ffi::c_int, ::std::ffi::c_int, *const f64, ::std::ffi::c_int) -> AxumDslVipsImage,
          set_double: unsafe extern "C" fn(AxumDslVipsImage, *const ::std::ffi::c_char, f64),
          conv: unsafe extern "C" fn(AxumDslVipsImage, *mut AxumDslVipsImage, AxumDslVipsImage, ...) -> ::std::ffi::c_int,
          write_to_file: unsafe extern "C" fn(AxumDslVipsImage, *const ::std::ffi::c_char, ...) -> ::std::ffi::c_int,
          width: unsafe extern "C" fn(AxumDslVipsImage) -> ::std::ffi::c_int,
          height: unsafe extern "C" fn(AxumDslVipsImage) -> ::std::ffi::c_int,
          unref: unsafe extern "C" fn(*mut ::std::ffi::c_void),
          error_clear: unsafe extern "C" fn(),
      }

      // SAFETY: libvips is thread-safe once vips_init has run; the table only holds function pointers into it.
      #[allow(unsafe_code)]
      unsafe impl Send for AxumDslVips {}
      #[allow(unsafe_code)]
      unsafe impl Sync for AxumDslVips {}

      #[allow(unsafe_code)]
      fn axum_dsl_vips() -> Option<&'static AxumDslVips> {
          static VIPS: ::std::sync::OnceLock<Option<AxumDslVips>> = ::std::sync::OnceLock::new();
          VIPS.get_or_init(|| {
              // SAFETY: the symbols are libvips' and GObject's C functions with these signatures (vips/image.h,
              // vips/resample.h, vips/convolution.h, vips/conversion.h); vips_init runs once, before any other call.
              unsafe {
                  let library = ::libloading::Library::new("libvips.so.42").ok()?;
                  let init: unsafe extern "C" fn(*const ::std::ffi::c_char) -> ::std::ffi::c_int = *library.get(b"vips_init\0").ok()?;
                  let vips = AxumDslVips {
                      new_from_file: *library.get(b"vips_image_new_from_file\0").ok()?,
                      autorot: *library.get(b"vips_autorot\0").ok()?,
                      thumbnail_image: *library.get(b"vips_thumbnail_image\0").ok()?,
                      matrix: *library.get(b"vips_image_new_matrix_from_array\0").ok()?,
                      set_double: *library.get(b"vips_image_set_double\0").ok()?,
                      conv: *library.get(b"vips_conv\0").ok()?,
                      write_to_file: *library.get(b"vips_image_write_to_file\0").ok()?,
                      width: *library.get(b"vips_image_get_width\0").ok()?,
                      height: *library.get(b"vips_image_get_height\0").ok()?,
                      unref: *library.get(b"g_object_unref\0").ok()?,
                      error_clear: *library.get(b"vips_error_clear\0").ok()?,
                      _library: library,
                  };
                  if init(c"axum_dsl".as_ptr()) != 0 {
                      return None;
                  }
                  Some(vips)
              }
          })
          .as_ref()
      }

      // ImageProcessing::Vips#resize_to_limit, then the save; the variant's width and height.
      #[allow(unsafe_code)]
      fn axum_dsl_vips_resize_to_limit(vips: &AxumDslVips, source: &str, destination: &str, width: i32, height: i32) -> Option<(i64, i64)> {
          let source = ::std::ffi::CString::new(source).ok()?;
          let destination = ::std::ffi::CString::new(destination).ok()?;
          let end: *const ::std::ffi::c_char = ::std::ptr::null();
          // SAFETY: each image is a live VipsImage from the call before it and is unreferenced exactly once; the
          // option lists are (name, value) pairs of the C types libvips reads (int, VipsSize, gboolean, VipsPrecision),
          // ended by NULL.
          unsafe {
              let input = (vips.new_from_file)(source.as_ptr(), end);
              if input.is_null() {
                  (vips.error_clear)();
                  return None;
              }
              let mut rotated: AxumDslVipsImage = ::std::ptr::null_mut();
              let failed = (vips.autorot)(input, &mut rotated, end) != 0;
              (vips.unref)(input);
              if failed {
                  (vips.error_clear)();
                  return None;
              }
              let mut thumbnail: AxumDslVipsImage = ::std::ptr::null_mut();
              // size: VIPS_SIZE_DOWN (2); no_rotate: TRUE.
              let failed = (vips.thumbnail_image)(rotated, &mut thumbnail, width, c"height".as_ptr(), height, c"size".as_ptr(), 2 as ::std::ffi::c_int,
                                                  c"no_rotate".as_ptr(), 1 as ::std::ffi::c_int, end) != 0;
              (vips.unref)(rotated);
              if failed {
                  (vips.error_clear)();
                  return None;
              }
              // ImageProcessing::Vips::Processor::SHARPEN_MASK: Vips::Image.new_from_array(mask, 24), offset 0.
              let mask_values: [f64; 9] = [-1.0, -1.0, -1.0, -1.0, 32.0, -1.0, -1.0, -1.0, -1.0];
              let mask = (vips.matrix)(3, 3, mask_values.as_ptr(), 9);
              (vips.set_double)(mask, c"scale".as_ptr(), 24.0);
              (vips.set_double)(mask, c"offset".as_ptr(), 0.0);
              let mut sharpened: AxumDslVipsImage = ::std::ptr::null_mut();
              // precision: VIPS_PRECISION_INTEGER (0).
              let failed = (vips.conv)(thumbnail, &mut sharpened, mask, c"precision".as_ptr(), 0 as ::std::ffi::c_int, end) != 0;
              (vips.unref)(thumbnail);
              (vips.unref)(mask);
              if failed {
                  (vips.error_clear)();
                  return None;
              }
              let written = (vips.write_to_file)(sharpened, destination.as_ptr(), end) == 0;
              let size = (i64::from((vips.width)(sharpened)), i64::from((vips.height)(sharpened)));
              (vips.unref)(sharpened);
              if !written {
                  (vips.error_clear)();
                  return None;
              }
              Some(size)
          }
      }

      // image_variant(path, filename, width, height): the variant as an upload, or None (no libvips, or an image it
      // cannot read or write). The work runs on tokio's blocking pool; the file goes through a temporary path with the
      // variant's extension, as ImageProcessing's Tempfile does.
      async fn axum_dsl_image_variant(source: &str, filename: &str, width: i64, height: i64) -> Option<AxumDslUpload> {
          let format = filename.rsplit_once('.').map(|(_, ext)| ext.to_ascii_lowercase())?;
          let content_type = match format.as_str() {
              "png" => "image/png",
              "webp" => "image/webp",
              "jpg" | "jpeg" => "image/jpeg",
              "gif" => "image/gif",
              _ => return None,
          };
          let (source, filename) = (source.to_string(), filename.to_string());
          let (width, height) = (i32::try_from(width).ok()?, i32::try_from(height).ok()?);
          ::tokio::task::spawn_blocking(move || {
              let vips = axum_dsl_vips()?;
              static SERIAL: ::std::sync::atomic::AtomicU64 = ::std::sync::atomic::AtomicU64::new(0);
              let serial = SERIAL.fetch_add(1, ::std::sync::atomic::Ordering::Relaxed);
              let temporary = ::std::env::temp_dir().join(format!("axum_dsl_variant_{}_{serial}.{format}", ::std::process::id()));
              let temporary_path = temporary.to_str()?.to_string();
              let dimensions = axum_dsl_vips_resize_to_limit(vips, &source, &temporary_path, width, height);
              let bytes = ::std::fs::read(&temporary).ok();
              let _ = ::std::fs::remove_file(&temporary);
              let ((variant_width, variant_height), bytes) = (dimensions?, bytes?);
              Some(AxumDslUpload {
                  filename,
                  content_type: content_type.to_string(),
                  size: bytes.len() as i64,
                  checksum: axum_dsl_upload_checksum(&bytes),
                  metadata: format!(r#"{{"identified":true,"width":{variant_width},"height":{variant_height},"analyzed":true}}"#),
                  bytes,
              })
          })
          .await
          .ok()
          .flatten()
      }
    RS
  end
end
