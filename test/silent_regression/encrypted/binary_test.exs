defmodule SilentRegression.Encrypted.BinaryTest do
  use ExUnit.Case, async: true

  alias SilentRegression.Encrypted.Binary

  test "encrypts with randomized authenticated ciphertext and decrypts losslessly" do
    plaintext = "sk-test-sentinel-never-store-in-plaintext"

    assert {:ok, first_ciphertext} = Binary.dump(plaintext)
    assert {:ok, second_ciphertext} = Binary.dump(plaintext)

    refute first_ciphertext == plaintext
    refute second_ciphertext == plaintext
    refute first_ciphertext == second_ciphertext
    assert :binary.match(first_ciphertext, plaintext) == :nomatch

    assert {:ok, ^plaintext} = Binary.load(first_ciphertext)
    assert {:ok, ^plaintext} = Binary.load(second_ciphertext)

    prefix_size = byte_size(first_ciphertext) - 1

    tampered_ciphertext =
      binary_part(first_ciphertext, 0, prefix_size) <>
        <<Bitwise.bxor(:binary.last(first_ciphertext), 1)>>

    assert :error = Binary.load(tampered_ciphertext)
  end
end
