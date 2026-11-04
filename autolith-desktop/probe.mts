import { attach, discover, lispString, query } from './localgroup.mjs';

const [command = 'list', id, ...args] = process.argv.slice(2);
const records = await discover();
if (command === 'list') {
  console.log(JSON.stringify(records.map(({ id, pid }) => ({ id, pid })), null, 2));
} else {
  const record = records.find((item) => item.id === id);
  if (!record) throw new Error('Pass a full running session ID from the list command.');
  if (command === 'send') {
    let terminal: ReturnType<typeof attach>;
    terminal = attach(record, 'take-over', (event) => {
      if (event.kind === 'attached') terminal.input(`(:line ${lispString(args.join(' '))})`);
      if (event.kind === 'output') process.stdout.write(event.text);
      if (event.kind === 'closed') console.error(event.message);
    });
    process.on('SIGINT', () => terminal.close());
  } else {
    if (command !== 'snapshot' && command !== 'models' && command !== 'commands' && command !== 'generations' && command !== 'watch') throw new Error('Unknown command');
    do {
      console.log(JSON.stringify(await query(record, `desktop-${command === 'watch' ? 'snapshot' : command}`)));
      if (command === 'watch') await new Promise((resolve) => setTimeout(resolve, 500));
    } while (command === 'watch');
  }
}
