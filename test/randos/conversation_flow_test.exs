defmodule Randos.ConversationFlowTest do
  use ExUnit.Case, async: true

  alias Randos.ConversationFlow

  describe "transition/2" do
    test "allows the mocked product skeleton state transitions" do
      assert {:ok, :looking} = ConversationFlow.transition(:idle, :looking)
      assert {:ok, :idle} = ConversationFlow.transition(:looking, :idle)
      assert {:ok, :connecting} = ConversationFlow.transition(:looking, :connecting)
      assert {:ok, :in_call} = ConversationFlow.transition(:connecting, :in_call)
      assert {:ok, :idle} = ConversationFlow.transition(:connecting, :idle)
      assert {:ok, :extension_pending} = ConversationFlow.transition(:in_call, :extension_pending)
      assert {:ok, :in_call} = ConversationFlow.transition(:extension_pending, :in_call)
      assert {:ok, :looking} = ConversationFlow.transition(:extension_pending, :looking)
      assert {:ok, :idle} = ConversationFlow.transition(:extension_pending, :idle)
      assert {:ok, :looking} = ConversationFlow.transition(:in_call, :looking)
      assert {:ok, :idle} = ConversationFlow.transition(:in_call, :idle)
    end

    test "rejects unsupported jumps" do
      assert {:error, :invalid_transition} = ConversationFlow.transition(:idle, :in_call)

      assert {:error, :invalid_transition} =
               ConversationFlow.transition(:looking, :extension_pending)
    end
  end
end
