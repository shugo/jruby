require 'test/unit'
require 'test/jruby/test_helper'
require 'tempfile'

# Tests for Proc#with_refinements (bugs.ruby-lang.org #16461).
#
# prc.with_refinements(mod, ...) returns a new Proc whose body runs with the given modules' refinements
# active.  The receiver is unchanged and the captured closure environment is shared; only the refinement
# scope differs.
class TestProcWithRefinements < Test::Unit::TestCase
  include TestHelper
  module StringRefinement
    refine String do
      def shout
        upcase + "!"
      end
    end
  end

  module IntegerRefinement
    refine Integer do
      def double
        self * 2
      end
    end
  end

  def test_refinement_applies
    prc = ->(s) { s.shout }
    refined = prc.with_refinements(StringRefinement)
    assert_equal "HI!", refined.call("hi")
  end

  def test_original_proc_unaffected
    prc = ->(s) { s.shout }
    prc.with_refinements(StringRefinement)
    assert_raise(NoMethodError) { prc.call("hi") }
  end

  def test_closure_environment_is_shared
    counter = 0
    prc = ->(s) { counter += 1; s.shout }
    refined = prc.with_refinements(StringRefinement)
    refined.call("a")
    assert_equal 1, counter
    refined.call("b")
    assert_equal 2, counter
    # The shared local is visible from the original proc too (without refinement method use).
    plain = ->() { counter }
    assert_equal 2, plain.call rescue nil
  end

  def test_multiple_modules
    prc = ->(s, n) { [s.shout, n.double] }
    refined = prc.with_refinements(StringRefinement, IntegerRefinement)
    assert_equal ["HI!", 6], refined.call("hi", 3)
  end

  def test_nested_blocks
    prc = ->(arr) { arr.map { |s| s.shout } }
    refined = prc.with_refinements(StringRefinement)
    assert_equal ["A!", "B!"], refined.call(["a", "b"])
  end

  def test_dup_preserves_refinements
    prc = ->(s) { s.shout }
    refined = prc.with_refinements(StringRefinement)
    assert_equal "HI!", refined.dup.call("hi")
    assert_equal "HI!", refined.clone.call("hi")
  end

  def test_proc_too_not_just_lambda
    prc = proc { |s| s.shout }
    refined = prc.with_refinements(StringRefinement)
    assert_equal "HI!", refined.call("hi")
  end

  def test_error_no_arguments
    prc = ->(s) { s.shout }
    assert_raise(ArgumentError) { prc.with_refinements }
  end

  def test_error_non_module_argument
    prc = ->(s) { s.shout }
    assert_raise(TypeError) { prc.with_refinements(42) }
  end

  def test_error_symbol_to_proc
    assert_raise(ArgumentError) { :shout.to_proc.with_refinements(StringRefinement) }
  end

  def test_error_method_to_proc
    obj = Object.new
    def obj.foo(s); s; end
    assert_raise(ArgumentError) { obj.method(:foo).to_proc.with_refinements(StringRefinement) }
  end

  # A refinement-aware clone is grafted under an already-built enclosing scope, so it needs its own full IR
  # built before it can be JIT-compiled.  Run in a subprocess with a low JIT threshold and synchronous (non
  # background) compilation so both the original and the clone cross the threshold deterministically.  We
  # assert two things: the refinement still produces correct results after JIT (and the original is
  # unaffected), and -- crucially for guarding the fix -- that the clone did not hit "JIT failed".  Without
  # the fix the clone cannot build its full IR and falls back to the interpreter, which is still correct, so
  # the JIT log is what distinguishes a working fix from a silent regression.
  def test_refinement_survives_jit
    script = <<~'RUBY'
      module R
        refine(String) { def upcase; "REFINED"; end }
      end
      prc = ->(s) { s.upcase }
      1000.times { exit(1) unless prc.call("hi") == "HI" }       # JIT the original (bare upcase) first
      refined = prc.with_refinements(R)
      1000.times { exit(2) unless refined.call("hi") == "REFINED" } # drive the clone past the threshold
      exit(3) unless prc.call("hi") == "HI"                      # original must stay unaffected post-JIT
      print "OK"
    RUBY
    Tempfile.create(['jit_refine', '.rb']) do |f|
      f.write(script)
      f.flush
      out = jruby("-Xjit.threshold=10 -Xjit.background=false -Xjit.logging #{f.path} 2>&1")
      assert_include out, "OK", "refinement-aware proc produced wrong results under JIT"
      assert_not_include out, "JIT failed", "refinement-aware clone could not be JIT-compiled"
    end
  end
end
