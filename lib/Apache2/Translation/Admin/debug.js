var debug_win;
var debug_win_init=('<button style="float: right;" onclick="debug_win.innerHTML=debug_win_init; return false;">clear</button>'+
		    '<button style="float: right;" onclick="debug_win.style.display=\'none\'; return false;">hide</button>');
function debug(str) {
  var h=new Object;
  h["<"]='&lt;';
  h[">"]='&gt;';
  h["&"]='&amp;';
  h['"']='&quot;';
  h[' ']='&nbsp;';
  h['\n']='<br>';
  if( !debug_win ) {
    var body=document.getElementsByTagName("BODY");
    debug_win=document.createElement('div');
    body[0].appendChild(debug_win);
    debug_win.id='debug';
    debug_win.innerHTML=debug_win_init;
  }
  debug_win.innerHTML+=str.replace(/[<>&\42\n ]/g, function(s){return h[s];});
  debug_win.style.display='';
}
