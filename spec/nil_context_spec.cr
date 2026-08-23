require "./spec_helper"

# `T = Nil` is unsupported (design section 3.1, section 15, D5). A caller with no
# domain context of its own uses FSM::Context instead.
#
# Design section 15 sketches a compile-time rejection inside the generic types:
#   {% if @type.type_vars.first.resolve == Nil %}
#     {% raise "... use FSM::Context ..." %}
#   {% end %}
# Whether that macro check is workable is unverified; documentation is the fallback
# either way, and the diagnostic should name FSM::Context. This spec lives in its
# own file so it can be dropped if the macro proves unworkable. It shells out to
# `crystal build` on a tiny program that instantiates Machine(Nil) and asserts the
# compile fails with a message naming FSM::Context.
describe "Machine(Nil)" do
  it "is rejected at compile time with a diagnostic naming FSM::Context" do
    # Crystal's `require` resolves relative to the requiring file's directory (or a
    # shard name); it does not accept absolute paths. The probe therefore lives in
    # this spec directory and requires the source with a relative path, so the
    # compile fails on the Machine(Nil) rejection rather than on a missing require.
    program : String = <<-CRYSTAL
      require "../src/fsm"
      FSM::Machine(Nil).build("nil-context") { |m| }
      CRYSTAL

    tmp : String = File.join(__DIR__, "nil_context_probe_#{Process.pid}.cr")
    File.write(tmp, program)

    output : IO::Memory = IO::Memory.new
    status : Process::Status = Process.run(
      "crystal",
      ["build", "--no-codegen", tmp],
      output: output,
      error: output,
    )
    File.delete(tmp)

    status.success?.should be_false
    output.to_s.should contain "FSM::Context"
  end
end
