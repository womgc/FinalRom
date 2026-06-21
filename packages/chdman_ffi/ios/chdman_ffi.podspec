#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint chdman_ffi.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'chdman_ffi'
  s.version          = '0.0.1'
  s.summary          = 'FFI bindings to MAME CHD (chdman) for CD CHD create/extract.'
  s.description      = <<-DESC
FFI bindings to MAME's CHD library for creating and extracting CD CHD images.
                       DESC
  s.homepage         = 'https://github.com/yasome'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'yasome' => 'aldwalshafy@gmail.com' }
  s.source           = { :path => '.' }

  # Compiles the shared C-ABI wrapper. The stub is built unless the vendored
  # MAME chd sources are added: to enable real CD support on iOS, add
  # '../src/chd/**/*.{c,cpp}' to source_files below and append
  # '-DCHDMAN_AVAILABLE=1' to GCC_PREPROCESSOR_DEFINITIONS, then vendor the
  # sources per src/chd/PLACEHOLDER.md.
  s.source_files = '../src/chdman_ffi.{h,cpp}'
  s.public_header_files = '../src/chdman_ffi.h'

  s.dependency 'Flutter'
  s.platform = :ios, '12.0'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
  }
  s.swift_version = '5.0'
end
