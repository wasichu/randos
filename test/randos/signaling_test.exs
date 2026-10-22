defmodule Randos.SignalingTest do
  use ExUnit.Case, async: true

  alias Randos.Matchmaking.{Entry, Match}
  alias Randos.Signaling

  defp match do
    entry = fn id ->
      %Entry{
        audio?: true,
        id: id,
        pid: self(),
        topic: "topic:#{id}",
        speaks_language: "en",
        hears_languages: ["es"]
      }
    end

    %Match{id: "match-1", participant_a: entry.("a"), participant_b: entry.("b")}
  end

  test "casts supported signaling types without creating atoms from unknown input" do
    assert {:ok, :offer} = Signaling.cast_type("offer")
    assert {:ok, :ice_candidate} = Signaling.cast_type(:ice_candidate)
    assert {:error, :unsupported_signal_type} = Signaling.cast_type("not_a_supported_signal")
  end

  test "builds a relay message for the peer" do
    call = %Randos.Calls.Call{id: "call-1", pid: self(), match: match()}

    assert {:ok, message} =
             Signaling.build_message(call, "a", "offer", %{"sdp" => "mock-sdp"})

    assert message.call_id == "call-1"
    assert message.type == :offer
    assert message.from_participant_id == "a"
    assert message.to_participant_id == "b"
    assert message.payload == %{"sdp" => "mock-sdp"}
    assert is_integer(message.sent_at_unix_ms)
  end

  describe "relay_only/2 (a relay-only call's relayed signals)" do
    @host "candidate:1 1 udp 2122260223 192.168.1.5 54321 typ host generation 0 ufrag abcd"
    @srflx "candidate:2 1 udp 1686052607 198.51.100.7 61234 typ srflx raddr 192.168.1.5 rport 54321"
    @relay "candidate:3 1 udp 41885439 203.0.113.9 50000 typ relay raddr 198.51.100.7 rport 61234 generation 0"
    @relay_zeroed "candidate:3 1 udp 41885439 203.0.113.9 50000 typ relay raddr 0.0.0.0 rport 0 generation 0"

    defp candidate(line),
      do: %{"candidate" => %{"candidate" => line, "sdpMid" => "0", "sdpMLineIndex" => 0}}

    test "drops direct candidates and hides a relay candidate's related address" do
      assert Signaling.relay_only(:ice_candidate, candidate(@host)) == :drop
      assert Signaling.relay_only(:ice_candidate, candidate(@srflx)) == :drop

      assert Signaling.relay_only(
               :ice_candidate,
               candidate("candidate:4 1 udp 1 a.local 5 typ prflx")
             ) == :drop

      assert Signaling.relay_only(:ice_candidate, candidate("not a candidate")) == :drop
      assert Signaling.relay_only(:ice_candidate, %{"candidate" => nil}) == :drop

      assert Signaling.relay_only(:ice_candidate, candidate(@relay)) ==
               {:ok, candidate(@relay_zeroed)}

      # Without a related address (str0m's), a relay candidate passes as is.
      plain = "candidate:5 1 udp 16777215 203.0.113.9 50001 typ relay"
      assert Signaling.relay_only(:ice_candidate, candidate(plain)) == {:ok, candidate(plain)}
      # End of candidates.
      assert Signaling.relay_only(:ice_candidate, candidate("")) == {:ok, candidate("")}
    end

    test "in SDP, changes only candidates and addresses ICE doesn't use" do
      lines = fn list -> Enum.map_join(list, &(&1 <> "\r\n")) end

      kept = [
        "v=0",
        "s=-",
        "t=0 0",
        "a=group:BUNDLE 0",
        "m=audio 9 UDP/TLS/RTP/SAVPF 111",
        "a=ice-ufrag:F7gI",
        "a=ice-pwd:x9cml/YzichV2+XlhiMu8g",
        "a=fingerprint:sha-256 49:66:12:17:0D:1C:91:AE:57:4C:C6:36:DD:D5:97:D2:7D:62:C9:9A:7F:B9:A3:F7:70:03:EB:65:3E:83:18:9C",
        "a=setup:actpass",
        "a=mid:0",
        "a=rtpmap:111 opus/48000/2"
      ]

      sdp =
        lines.([
          "o=- 4611731400430051336 2 IN IP4 198.51.100.7",
          "c=IN IP4 198.51.100.7",
          "a=rtcp:61234 IN IP4 198.51.100.7",
          "a=" <> @host,
          "a=" <> @srflx,
          "a=" <> @relay
          | kept
        ])

      assert {:ok, %{"sdp" => %{"type" => "offer", "sdp" => safe}}} =
               Signaling.relay_only(:offer, %{"sdp" => %{"type" => "offer", "sdp" => sdp}})

      assert safe ==
               lines.([
                 "o=- 4611731400430051336 2 IN IP4 0.0.0.0",
                 "c=IN IP4 0.0.0.0",
                 "a=rtcp:61234 IN IP4 0.0.0.0",
                 "a=" <> @relay_zeroed
                 | kept
               ])

      refute safe =~ "198.51.100.7"
      refute safe =~ "192.168.1.5"
      # IPv6 addresses too.
      assert {:ok, %{"sdp" => %{"sdp" => "c=IN IP6 ::\r\n"}}} =
               Signaling.relay_only(:answer, %{
                 "sdp" => %{"type" => "answer", "sdp" => "c=IN IP6 2001:db8::1\r\n"}
               })
    end

    test "an ICE restart offer keeps its new credentials and ice-options, loses its host candidates" do
      restart =
        Enum.map_join(
          [
            "v=0",
            "o=- 4611731400430051336 3 IN IP4 0.0.0.0",
            "m=audio 9 UDP/TLS/RTP/SAVPF 111",
            "a=ice-ufrag:Zq3W",
            "a=ice-pwd:N0w4n3wpassw0rdF0rTh1sRestart",
            "a=ice-options:trickle",
            "a=" <> @host,
            "a=" <> @relay
          ],
          &(&1 <> "\r\n")
        )

      assert {:ok, %{"sdp" => %{"sdp" => safe}}} =
               Signaling.relay_only(:offer, %{"sdp" => %{"type" => "offer", "sdp" => restart}})

      assert safe =~ "a=ice-ufrag:Zq3W\r\n"
      assert safe =~ "a=ice-pwd:N0w4n3wpassw0rdF0rTh1sRestart\r\n"
      assert safe =~ "a=ice-options:trickle\r\n"
      assert safe =~ @relay_zeroed
      refute safe =~ "192.168.1.5"
    end

    test "anything else is dropped rather than relayed unchecked" do
      assert Signaling.relay_only(:offer, %{"sdp" => "not a description"}) == :drop
      assert Signaling.relay_only(:answer, %{}) == :drop
    end
  end
end
