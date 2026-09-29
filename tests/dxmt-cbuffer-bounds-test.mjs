// Exercise the production shader-load emitter, optimised and run by LLVM 15's
// IR interpreter, plus actual D3D11 binding code. This does not substitute a
// CPU bounds-check model. Builds against 03-llvm15.sh's macOS install, which
// has no native backend for a JIT.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';

const root = path.resolve(import.meta.dirname, '..');
const scratch = path.join(root, '.deploy/tests');
fs.mkdirSync(scratch, {recursive: true});
const read = name => fs.readFileSync(path.join(root, 'third_party/dxmt/src', name), 'utf8');
const source = read('airconv/nt/dxbc_converter_base.cpp');
const begin = source.indexOf('llvm::Value *\nConverter::LoadOperand(const SrcOperandConstantBuffer');
const end = source.indexOf('\nllvm::Value *', begin + 1);
assert(begin >= 0 && end > begin);
const context = read('dxmt/dxmt_context.cpp');
const rangeBegin = context.indexOf('      auto valid_length = cbuf.buffer.ptr()');
const rangeEnd = context.indexOf('      encoded_buffer', rangeBegin);
assert(rangeBegin >= 0 && rangeEnd > rangeBegin);
assert(context.includes('encoded_buffer[arg.StructurePtrOffset + 1] = valid_length >> 4;'));
assert(context.includes('if (!valid_length) {'));
const impl = read('d3d11/d3d11_context_impl.cpp');
const bindingBegin = impl.indexOf('  template <PipelineStage Stage>\n  void\n  SetConstantBuffer(');
const bindingEnd = impl.indexOf('\n  template <PipelineStage Stage>', bindingBegin + 1);
assert(bindingBegin >= 0 && bindingEnd > bindingBegin);
assert(impl.includes('PreAllocateArgumentBuffer(ConstantBufferCount << 4, 32)'));
assert(impl.includes('length = entry.NumConstants << 4'));
assert(read('dxmt/dxmt_shader_cache.hpp').includes('kDXMTShaderCacheVersion = 19'));
assert(read('airconv/airconv_public.h').includes('return SM50BindingSlot * 2;'));
assert(read('airconv/dxbc_converter.cpp').includes('cbv.arg_length_index = binding_table_cbuffer.DefineInteger64'));

const test = `
#include <algorithm>
#include <array>
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <map>
#include <mutex>
#include <memory>
#include <vector>
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/Verifier.h"
#include "llvm/ExecutionEngine/ExecutionEngine.h"
#include "llvm/ExecutionEngine/GenericValue.h"
#include "llvm/ExecutionEngine/Interpreter.h"
#include "llvm/Passes/PassBuilder.h"
using mask_t = uint32_t;
struct SrcOperandConstantBuffer { struct { int swizzle; } _; unsigned rangeid; llvm::Value *regindex; };
int ComponentFromScalarMask(mask_t mask, int component) { return mask == 15 ? -1 : component; }
struct Binding {
  llvm::Value *value;
  Binding operator()(std::nullptr_t) { return *this; }
  llvm::Expected<llvm::Value *> build(int &) { return value; }
};
struct Resources { std::map<unsigned, Binding> cb_range_map, cb_length_map; };
struct Air {
  llvm::IRBuilder<> &ir;
  llvm::Type *getIntTy(unsigned n = 1) {
    if (n == 1) return ir.getInt32Ty();
    return llvm::FixedVectorType::get(ir.getInt32Ty(), n);
  }
};
struct Converter {
  Air air;
  llvm::IRBuilder<> &ir;
  Resources res;
  int ctx = 0;
  llvm::Value *LoadOperandIndex(llvm::Value *index) { return index; }
  llvm::Value *ApplySrcModifier(decltype(SrcOperandConstantBuffer::_), llvm::Value *v, mask_t) { return v; }
  llvm::Value *LoadOperand(const SrcOperandConstantBuffer &, mask_t);
};
${source.slice(begin, end)}

using UINT = unsigned;
using mutex_t = std::mutex;
enum PipelineStage { Vertex, Pixel };
struct ID3D11Buffer {
  uint64_t bytes;
  ID3D11Buffer *buffer() { return this; }
  uint64_t length() { return bytes; }
};
struct Ptr {
  ID3D11Buffer *value;
  ID3D11Buffer *ptr() { return value; }
  ID3D11Buffer *operator->() { return value; }
};
struct CB { Ptr buffer; uint64_t offset; unsigned length; };
uint64_t boundLength(CB cbuf) {
${context.slice(rangeBegin, rangeEnd)}
  return valid_length;
}
struct ArgumentEncodingContext {
  struct Bound { ID3D11Buffer *buffer; uint64_t offset; unsigned length; } bound[2][14]{};
  int changes = 0;
  template<PipelineStage Stage>
  void bindConstantBuffer(unsigned slot, uint64_t offset, unsigned length, ID3D11Buffer *buffer) {
    bound[Stage][slot] = {buffer, offset, length}; ++changes;
  }
  template<PipelineStage Stage>
  void bindConstantBufferRange(unsigned slot, uint64_t offset, unsigned length) {
    bound[Stage][slot].offset = offset; bound[Stage][slot].length = length; ++changes;
  }
};
struct BindingSet {
  struct Entry { ID3D11Buffer *RawPointer = nullptr; ID3D11Buffer *Buffer = nullptr; UINT FirstConstant = 0, NumConstants = 0; } entries[14];
  Entry &bind(unsigned slot, Entry incoming, bool &replaced) {
    replaced = entries[slot].RawPointer != incoming.RawPointer;
    if (replaced) entries[slot] = incoming;
    return entries[slot];
  }
  bool unbind(unsigned slot) { bool had = entries[slot].RawPointer; entries[slot] = {}; return had; }
  void set_dirty(unsigned) {}
};
ID3D11Buffer *GetResourceCommon(ID3D11Buffer *p) { return p; }
ID3D11Buffer *forward_rc(ID3D11Buffer *p) { return p; }
struct DeviceContext {
  mutex_t mutex;
  struct { struct { BindingSet ConstantBuffers; } ShaderStages[2]; } state_;
  ArgumentEncodingContext enc;
  template<class F> void EmitST(F fn) { fn(enc); }
${impl.slice(bindingBegin, bindingEnd)}
};

int main() {
  setbuf(stdout, nullptr);
  puts("CBUFFER: binding transitions");
  ID3D11Buffer small{32}, large{131072};
  assert(boundLength({{&small}, 0, 65536}) == 32);
  assert(boundLength({{&large}, 256, 512}) == 512);
  assert(boundLength({{&small}, 16, 65536}) == 16);
  assert(boundLength({{&small}, 32, 65536}) == 0);
  assert(boundLength({{&small}, 0xfffffff00ULL, 65536}) == 0);
  assert(boundLength({{&small}, 0, 0}) == 0);
  assert(boundLength({{nullptr}, 0, 65536}) == 0);
  DeviceContext dc;
  ID3D11Buffer *p = &large;
  unsigned first = 16, count = 32;
  dc.SetConstantBuffer<Vertex>(0, 1, &p, &first, &count);
  assert(dc.enc.bound[0][0].offset == 256 && dc.enc.bound[0][0].length == 512);
  count = 16; dc.SetConstantBuffer<Vertex>(0, 1, &p, &first, &count);
  assert(dc.enc.bound[0][0].length == 256); // length-only rebind
  first = 32; dc.SetConstantBuffer<Vertex>(0, 1, &p, &first, &count);
  assert(dc.enc.bound[0][0].offset == 512);
  dc.SetConstantBuffer<Vertex>(0, 1, &p, nullptr, nullptr);
  assert(dc.enc.bound[0][0].offset == 0 && dc.enc.bound[0][0].length == 65536);
  auto changes = dc.enc.changes;
  dc.SetConstantBuffer<Vertex>(0, 1, &p, nullptr, nullptr);
  assert(dc.enc.changes == changes);
  count = 8192; dc.SetConstantBuffer<Vertex>(0, 1, &p, &first, &count);
  assert(dc.enc.changes == changes); // invalid call leaves binding untouched
  first = 0xfffffff0u; count = 16;
  dc.SetConstantBuffer<Vertex>(0, 1, &p, &first, &count);
  assert(dc.enc.bound[0][0].offset == 0xfffffff00ULL);
  p = nullptr; dc.SetConstantBuffer<Vertex>(0, 1, &p, nullptr, nullptr);
  assert(dc.enc.bound[0][0].buffer == nullptr && dc.enc.bound[0][0].length == 0);

  puts("CBUFFER: LLVM IR generation");
  llvm::LLVMContext ctx; ctx.setOpaquePointers(false);
  auto module = std::make_unique<llvm::Module>("cbuffer-bounds", ctx);
  llvm::IRBuilder<> ir(ctx);
  auto vec = llvm::FixedVectorType::get(ir.getInt32Ty(), 4);
  for (int comp = -1; comp < 4; ++comp) {
    auto ft = llvm::FunctionType::get(ir.getVoidTy(), {vec->getPointerTo(), ir.getInt64Ty(), ir.getInt32Ty(), ir.getInt32Ty()->getPointerTo()}, false);
    auto fn = llvm::Function::Create(ft, llvm::Function::ExternalLinkage, "load" + std::to_string(comp + 1), *module);
    ir.SetInsertPoint(llvm::BasicBlock::Create(ctx, "entry", fn));
    Converter converter{{ir}, ir, {{{7, {fn->getArg(0)}}}, {{7, {fn->getArg(1)}}}}};
    auto value = converter.LoadOperand({{comp}, 7, fn->getArg(2)}, comp < 0 ? 15 : 1);
    ir.CreateStore(value, ir.CreateBitCast(fn->getArg(3), value->getType()->getPointerTo()));
    ir.CreateRetVoid();
  }
  assert(!llvm::verifyModule(*module, &llvm::errs()));
  llvm::LoopAnalysisManager lam; llvm::FunctionAnalysisManager fam;
  llvm::CGSCCAnalysisManager cgam; llvm::ModuleAnalysisManager mam;
  llvm::PassBuilder pb; pb.registerModuleAnalyses(mam); pb.registerCGSCCAnalyses(cgam);
  pb.registerFunctionAnalyses(fam); pb.registerLoopAnalyses(lam);
  pb.crossRegisterProxies(lam, fam, cgam, mam);
  puts("CBUFFER: LLVM O2");
  auto passes = pb.buildPerModuleDefaultPipeline(llvm::OptimizationLevel::O2);
  passes.run(*module, mam);
  assert(!llvm::verifyModule(*module, &llvm::errs()));
  std::string error;
  auto engine = std::unique_ptr<llvm::ExecutionEngine>(llvm::EngineBuilder(std::move(module)).setErrorStr(&error).setEngineKind(llvm::EngineKind::Interpreter).create());
  if (!engine) { llvm::errs() << error; return 1; }
  puts("CBUFFER: LLVM interpreter");
  alignas(16) uint32_t values[8] = {11, 22, 33, 44, 55, 66, 77, 88};
  for (int comp = -1; comp < 4; ++comp) {
    auto fn = engine->FindFunctionNamed("load" + std::to_string(comp + 1));
    assert(fn);
    for (uint64_t length : {0, 1, 2}) for (uint32_t index : {0u, 1u, 2u, 4096u, 0x80000000u, 0xffffffffu}) {
      alignas(16) uint32_t out[4] = {999, 999, 999, 999};
      std::vector<llvm::GenericValue> args(4);
      args[0] = llvm::PTOGV(values);
      args[1].IntVal = llvm::APInt(64, length);
      args[2].IntVal = llvm::APInt(32, index);
      args[3] = llvm::PTOGV(out);
      engine->runFunction(fn, args);
      for (int lane = 0; lane < (comp < 0 ? 4 : 1); ++lane)
        assert(out[lane] == (index < length ? values[index * 4 + (comp < 0 ? lane : comp)] : 0));
    }
  }
  puts("CBUFFER PASS: optimized production scalar/vector LLVM loads; OOB/negative/empty -> zero; bound range intersection; length-only/redundant/whole-buffer rebinds; 64-bit offsets; null bindings; cache ABI");
}
`;
const input = path.join(scratch, 'dxmt-cbuffer-bounds-test.cpp');
const output = path.join(scratch, 'dxmt-cbuffer-bounds-test');
fs.writeFileSync(input, test);
const llvm = path.join(root, 'toolchains/llvm15-macos');
assert(fs.existsSync(path.join(llvm, 'lib/libLLVMInterpreter.a')), 'no LLVM 15 at ' + llvm + '; run TARGET=macos scripts/03-llvm15.sh');
// The flags llvm-config would give (the install has no tools): LLVM is built
// without RTTI or exceptions. ld64 takes only the archive members it needs.
const archives = fs.readdirSync(path.join(llvm, 'lib')).filter(f => /^libLLVM.*\.a$/.test(f)).map(f => path.join(llvm, 'lib', f));
const flags = ['-I' + path.join(llvm, 'include'), '-fno-rtti', '-fno-exceptions', '-D__STDC_CONSTANT_MACROS',
  '-D__STDC_FORMAT_MACROS', '-D__STDC_LIMIT_MACROS', ...archives, '-lz', '-lcurses'];
// Xcode's ASan can deadlock during dyld initialization on this host OS;
// UBSan remains enabled. Opt into ASan on hosts with a working runtime.
const sanitizers = process.env.DXMT_TEST_ASAN === '1' ? 'address,undefined' : 'undefined';
execFileSync('xcrun', ['--sdk', 'macosx', 'clang++', ...flags, '-std=c++20', '-O1', '-fsanitize=' + sanitizers, input, '-o', output], {stdio: 'inherit'});
execFileSync(output, {stdio: 'inherit', timeout: 30000});
