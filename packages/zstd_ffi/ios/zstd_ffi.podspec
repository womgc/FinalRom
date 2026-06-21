#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint zstd_ffi.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'zstd_ffi'
  s.version          = '0.0.1'
  s.summary          = 'FFI bindings to libzstd streaming compression.'
  s.description      = <<-DESC
FFI bindings to the native Zstandard (libzstd) streaming compression API.
                       DESC
  s.homepage         = 'https://github.com/yasome'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'yasome' => 'aldwalshafy@gmail.com' }
  s.source           = { :path => '.' }

  # Compiles the shared C-ABI wrapper. The stub is built unless the vendored
  # libzstd sources are added: to enable real compression on iOS, add the zstd
  # lib sources to source_files, add '../src/zstd/lib' to header search paths,
  # and append '-DZSTD_AVAILABLE=1' to GCC_PREPROCESSOR_DEFINITIONS, then vendor
  # the sources per src/zstd/PLACEHOLDER.md.
  s.source_files = '../src/zstd_ffi.{h,c}'
  s.public_header_files = '../src/zstd_ffi.h'

  s.dependency 'Flutter'
  s.platform = :ios, '12.0'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
  }
  s.swift_version = '5.0'
end
