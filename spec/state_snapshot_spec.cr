require "./spec_helper"

# The runtime snapshot (design section 3.3, D13). `State` is a non-generic struct
# reporting the outcome of one transaction:
#   struct State { getter id : String; getter status : Status; getter error : Exception? }
#   enum Status { Success; Failed }
#
# By design the type does not enforce the invariant that Success carries no error
# and Failed carries one; construction is expected to maintain it. This issue
# (fsmcr-bfn.2) delivers the type and its shape. The snapshot becoming the public
# return value of Service#send and Service#current_state is fsmcr-crj's scope and
# is not spec'd here.
#
# Open question for the implementer: the exact constructor keyword arguments. These
# specs assume `State.new(id:, status:, error:)`.
describe FSM::State do
  it "constructs a Success snapshot with an id and no error" do
    state : FSM::State = FSM::State.new(id: "idle", status: FSM::Status::Success, error: nil)

    state.id.should eq "idle"
    state.status.should eq FSM::Status::Success
    state.error.should be_nil
  end

  it "constructs a Failed snapshot carrying the exception and the unchanged id" do
    boom : Exception = Exception.new("callback raised")
    state : FSM::State = FSM::State.new(id: "cave", status: FSM::Status::Failed, error: boom)

    state.id.should eq "cave"
    state.status.should eq FSM::Status::Failed
    state.error.should eq boom
  end
end

describe FSM::Status do
  it "distinguishes Success from Failed" do
    FSM::Status::Success.should_not eq FSM::Status::Failed
  end
end
