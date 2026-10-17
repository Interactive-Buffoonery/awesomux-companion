import readline from 'node:readline';
const ws=new WebSocket(process.argv[2]);
const pending=[];
ws.addEventListener('open',()=>{for(const line of pending)ws.send(line);});
ws.addEventListener('message',event=>process.stdout.write(String(event.data)+'\n'));
ws.addEventListener('error',()=>{process.stderr.write('websocket transport failed\n');process.exitCode=1;});
ws.addEventListener('close',()=>process.exit());
readline.createInterface({input:process.stdin}).on('line',line=>{if(ws.readyState===WebSocket.OPEN)ws.send(line);else pending.push(line);}).on('close',()=>ws.close());
