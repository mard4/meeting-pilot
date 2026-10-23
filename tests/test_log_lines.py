import io
import re
import sys
from pathlib import Path

from meeting_pilot.log_lines import StampedStream, run_logged, stamped, unstamped

STAMP = r"\[\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\] "


def test_stamped_puts_the_time_before_every_line_but_not_blank_ones() -> None:
    lines = stamped("first\n\nsecond\n").split("\n")
    assert re.fullmatch(STAMP + "first", lines[0])
    assert lines[1] == ""
    assert re.fullmatch(STAMP + "second", lines[2])
    assert unstamped(lines[2]) == "second"


def test_stamped_stream_stamps_lines_written_in_pieces() -> None:
    target = io.StringIO()
    stream = StampedStream(target)
    stream.write("Watching ")
    stream.write("the inbox\nTraceback:\n  File x\n")
    lines = target.getvalue().splitlines()
    assert len(lines) == 3
    assert re.fullmatch(STAMP + "Watching the inbox", lines[0])
    assert all(re.match(STAMP, line) for line in lines)


def test_run_logged_appends_the_command_and_its_stamped_output(tmp_path: Path) -> None:
    log = tmp_path / "helper.log"
    log.write_text("earlier\n", encoding="utf-8")
    code = run_logged([sys.executable, "-c", "import sys; print('one'); print('two', file=sys.stderr); sys.exit(3)"], log)
    assert code == 3
    lines = log.read_text(encoding="utf-8").splitlines()
    assert lines[0] == "earlier"
    assert re.match(STAMP + r"\$ ", lines[1])
    assert {unstamped(line) for line in lines[2:]} == {"one", "two"}
    assert all(re.match(STAMP, line) for line in lines[1:])
