var next_counter;

var opener=Array(' <img src="closed.gif"> ',
                 ' <img src="opening.gif"> ',
                 ' <img src="open.gif"> ');

function get_data( counter ) {
  var d=$('div'+counter);
  var v={ key: decodeURI(d.getAttribute('ADM_KEY')),
	  uri: decodeURI(d.getAttribute('ADM_URI')) };
  return v;
}

function set_data( counter, key, uri ) {
  var d=$('div'+counter);
  d.setAttribute('ADM_KEY', encodeURI(key));
  d.setAttribute('ADM_URI', encodeURI(uri));
}

function add_resizer( counter ) {
  var resizer=(typeof(counter)=='number' ? $('div'+counter) : $(counter))
                .getElementsByTagName('div');

  for( var i=0; i<resizer.length; i++ ) {
    if( resizer[i].className=='resizer' ) {
      new Draggable(resizer[i],
		    { constraint: 'vertical',
		      resizing_element: get_prev_sibling(resizer[i], 'textarea'),
		      starteffect: function(o) {
			this.resizing_height=this.resizing_element.offsetHeight;
		      },
		      change: function(o) {
			this.resizing_delta=o.currentDelta()[1];
		      },
		      endeffect: function(o) {
			this.resizing_element.style.height=
			  (this.resizing_height+this.resizing_delta)+'px';
			o.style.top=0;
		      },
		      snap: function(x,y) {
			if( this.resizing_height+y < 1 ) y=-this.resizing_height+1;
			return [x,y];
		      }
		    });
    }
  }
}

function xopen( counter ) {
  var data=get_data(counter);
  if( $('div'+counter).innerHTML.length>0 ) {
    Element.show( 'div'+counter );
    if( $('form'+counter).getAttribute('new_element') ) {
      $('reload'+counter).style.visibility='hidden';
      //Element.hide( 'reload'+counter );
    } else {
      $('reload'+counter).style.visibility='';
      //Element.show( 'reload'+counter );
    }
    Element.update( 'a'+counter, opener[2] );
  } else {
    Element.update( 'a'+counter, opener[1] );
    new Ajax.Updater( { success: 'div'+counter },
	  	      'index.html',
		      { method: 'post',
			asynchronous: 1,
			parameters: {
			  a: 'fetch',
			  key: data.key,
			  uri: data.uri,
			  counter: counter
			},
		        onComplete: function(req) {
			  if( 200<=req.status && req.status<300 ) {
			    add_resizer( counter );
			    Element.show( 'div'+counter );
			    $('save'+counter).style.visibility='hidden';
			    //Element.hide( 'save'+counter );
			    $('reload'+counter).style.visibility='';
			    //Element.show( 'reload'+counter );
			    Element.update( 'a'+counter, opener[2] );
			  } else {
			    Element.update( 'a'+counter, opener[0] );
			    var err;
			    var errcode;
			    try {
			      err=req.getResponseHeader("X-Error");
			      errcode=req.getResponseHeader("X-ErrorCode");
			    } catch(e) {}
			    if( err != null && err.length > 0 ) {
			      alert("Sorry, an error has occured.\n"+
				    "The server says: "+err);
			      if( errcode=="1" ) xbdelete(counter);
			    } else {
			      alert("Sorry, an error has occured.\n"+
				    "The server says: "+req.statusText+" ("+
				    req.status+")");
			    }
			  }
			}
		      } );
  }
}

function xreload( counter, o ) {
  o.blur();
  var data=get_data(counter);
  Element.update( 'a'+counter, opener[1] );
  new Ajax.Updater( { success: 'div'+counter },
	  	      'index.html',
		    { method: 'post',
		      asynchronous: 1,
		      parameters: {
		        a: 'fetch',
			key: data.key,
			uri: data.uri,
			counter: counter
		      },
		      onComplete: function(req) {
		        if( 200<=req.status && req.status<300 ) {
			  add_resizer( counter );
		          //Element.show( 'div'+counter );
			  $('save'+counter).style.visibility='hidden';
		          //Element.hide( 'save'+counter );
			  $('reload'+counter).style.visibility='';
		          //Element.show( 'reload'+counter );
		          Element.update( 'a'+counter, opener[2] );
			  var f=$('form'+counter);
			  update_header(counter, f.newkey.value, f.newuri.value);
		        } else {
		          Element.update( 'a'+counter, opener[2] );
			  var err;
			  var errcode;
			  try {
			    err=req.getResponseHeader("X-Error");
			    errcode=req.getResponseHeader("X-ErrorCode");
			  } catch(e) {}
			  if( err != null && err.length > 0 ) {
			    alert("Sorry, an error has occured.\n"+
				  "The server says: "+err);
			    if( errcode=="1" ) xbdelete(counter);
			  } else {
			    alert("Sorry, an error has occured.\n"+
				  "The server says: "+req.statusText+" ("+
				  req.status+")");
			  }
		        }
		      }
		    } );
  return false;
}

function xclose( counter ) {
  Element.hide( 'div'+counter );
  $('reload'+counter).style.visibility='hidden';
  //Element.hide( 'reload'+counter );
  Element.update( 'a'+counter, opener[0] );
}

function xtoggle( counter, o ) {
  o.blur();
  if( Element.visible( 'div'+counter ) ) {
    xclose( counter );
  } else {
    if( $('a'+counter).innerHTML == opener[1] ) {
      return false;
    }
    xopen( counter );
  }

  return false;
}

function xchanged( counter ) {
  $('save'+counter).style.visibility='';
  //Element.show( 'save'+counter );
  var f=$('form'+counter);
  update_header(counter, f.newkey.value, f.newuri.value);
  return false;
}

function xreorder( counter ) {
  var f=$('form'+counter);
  var tds=f.getElementsByTagName("td");
  var block=0;
  var oldblock;
  var order;

  for (var i=0; i<tds.length; i++) {
    if( tds[i].className.match(/^tdc\d+$/) ) {
      if( oldblock==null ) {
	oldblock=tds[i].getAttribute("ADM_BLOCK");
	order=-1;
      }
      var ta=tds[i].getElementsByTagName("textarea")[0];
      var blk=tds[i].getAttribute("ADM_BLOCK");
      var ord=tds[i].getAttribute("ADM_ORDER");
      var id =tds[i].getAttribute("ADM_ID");

      if( blk!=oldblock ) {
	oldblock=blk;
	block++;
	order=0;
      } else {
	order++;
      }
      //debug("oldblock="+oldblock+" block="+block+" oldord="+ord+" ord="+
      //    order+" id="+id+"\n");
      ta.name="action_"+oldblock+"_"+block+"_"+ord+"_"+order+"_"+id;
    }
  }
}

function update_header( counter, key, uri ) {
  if( uri==":PRE:" ) {
    Element.update( 'header'+counter, key.escapeHTML() );
  } else {
    Element.update( 'header'+counter,
		    key.escapeHTML()+" <img class=\"pfeil\" src=\"pfeil.gif\"> "+ uri.escapeHTML() );
  }
}

function xupdate( counter, o ) {
  o.blur();
  xreorder( counter );
  var params=$('form'+counter).getElements().inject
    ({}, function(hash, element) {
       element = $(element);
       if (element.disabled) return hash;
       var method = element.tagName.toLowerCase();
       var parameter = Form.Element.Serializers[method](element);

       if (parameter) {
	 var key = encodeURIComponent(parameter[0]);
	 if (key.length == 0) return hash;

	 if (parameter[1].constructor != Array)
	   parameter[1] = [parameter[1]];

	 hash[key]=parameter[1];
       }
       return hash;
     });
  params["a"]="update";
  params["counter"]=counter;
  var d=get_data(counter);
  params["key"]=d.key;
  params["uri"]=d.uri;
  Element.update( 'a'+counter, opener[1] );
  new Ajax.Updater( { success: 'div'+counter },
		    'index.html',
                    { method: 'post',
                      asynchronous: 1,
		      parameters: params,
		      onComplete: function(req) {
			if( 200<=req.status && req.status<300 ) {
			  add_resizer( counter );
			  $('save'+counter).style.visibility='hidden';
			  $('reload'+counter).style.visibility='';
			  var f=$('form'+counter);
			  set_data( counter, f.newkey.value, f.newuri.value );
			  update_header(counter, f.newkey.value, f.newuri.value);
			} else {
			  var err;
			  var errcode;
			  try {
			    err=req.getResponseHeader("X-Error");
			    errcode=req.getResponseHeader("X-ErrorCode");
			  } catch(e) {}
			  if( err != null && err.length > 0 ) {
			    if( errcode=='1' ) {
			      xbdelete(counter);
			    } else {
			      alert("Sorry, an error has occured.\n"+
				    "The server says: "+err);
			    }
			  } else {
			    alert("Sorry, an error has occured.\n"+
				  "The server says: "+req.statusText+" ("+
				  req.status+")");
			  }
			}
			Element.update( 'a'+counter, opener[2] );
		      }
                    } );
  return false;
}

function find_parent_by_tag( o, tag ) {
  tag=tag.toUpperCase();
  while( o && o.nodeName != tag ) {
    o=o.parentNode;
  }
  return o;
}

function get_form_counter( o ) {
  return find_parent_by_tag( o, 'form' ).getAttribute("ADM_COUNTER");
}

function xinsert( o, where ) {
  o.blur();
  var tr=find_parent_by_tag( o, 'tr' );
  var newnode=tr.cloneNode(true);
  
  var ta=newnode.getElementsByTagName("textarea")[0];
  var hidden=newnode.getElementsByTagName("td")[0];
  hidden.setAttribute("ADM_ORDER", "");
  hidden.setAttribute("ADM_ID", "");
  ta.value="";

  add_resizer( newnode );

  if( where<0 ) {
    tr.parentNode.insertBefore(newnode, tr);
  } else {
    if( tr.nextSibling ) {
      tr.parentNode.insertBefore(newnode, tr.nextSibling);
    } else {
      tr.parentNode.appendChild(newnode);
    }
  }

  $('save'+get_form_counter(tr)).style.visibility='';

  return false;
}

function find_next_free_form_block( o ) {
  var form=find_parent_by_tag( o, 'form' );
  var rc=form.getAttribute("ADM_NBLOCKS");
  form.setAttribute("ADM_NBLOCKS", rc+1);
  return rc;
}

function get_tr_block( o ) {
  //debug(o.inspect()+" class="+o.className+"\n");
  var rc=o.getElementsByTagName("td");
  if( rc.length==0 ) return -1;
  rc=rc[0].getAttribute("ADM_BLOCK");
  if( rc==null ) return -1;
  else return rc;
}

function get_next_sibling( tr, what ) {
  what=what.toUpperCase();
  while( tr=tr.nextSibling ) {
    if( tr.nodeName==what ) return tr;
  }
  return null;
}

function get_prev_sibling( tr, what ) {
  what=what.toUpperCase();
  while( tr=tr.previousSibling ) {
    if( tr.nodeName==what ) return tr;
  }
  return null;
}

function update_bg( o ) {
  var tbl=find_parent_by_tag( o, 'table' );
  var trs=tbl.getElementsByTagName("tr");
  var style=-1;
  var block=-1;

  for (var i=0; i<trs.length; i++) {
    var td=trs[i].getElementsByTagName("td");
    if( td.length && td[0].className.match(/^tdc\d+$/) ) {
      if( get_tr_block(trs[i])!=block ) {
	block=get_tr_block(trs[i]);
	style=(style+1)%3;
      }
      td[0].className='tdc'+(style+1);
    }
  }
}

function xbdelete( counter ) {
  var n=$('header'+counter);
  n=n.parentNode;
  var p=n.parentNode;
  p.removeChild(n);
  n=$('div'+counter);
  p=n.parentNode;
  p.removeChild(n);
}

function xbinsert( o, where ) {
  o.blur();
  var tr=find_parent_by_tag( o, 'tr' );
  var newnode=tr.cloneNode(true);
  
  var ta=newnode.getElementsByTagName("textarea")[0];
  var hidden=newnode.getElementsByTagName("td")[0];
  hidden.setAttribute("ADM_BLOCK", find_next_free_form_block( tr ));
  hidden.setAttribute("ADM_ORDER", "");
  hidden.setAttribute("ADM_ID", "");
  ta.value="";

  add_resizer( newnode );

  var myblock=get_tr_block( tr );

  //debug("myblock="+myblock+"\n");

  if( where<0 ) {
    var insert_before_this=tr;
    for( var x=get_prev_sibling(insert_before_this, 'tr');
	 x && get_tr_block(x)==myblock;
	 insert_before_this=x, x=get_prev_sibling(x, 'tr') );
    tr.parentNode.insertBefore(newnode, insert_before_this);
  } else {
    var insert_before_this;
    for( insert_before_this=get_next_sibling(tr, 'tr');
	 insert_before_this &&
	   get_tr_block(insert_before_this)==myblock;
	 insert_before_this=get_next_sibling(insert_before_this, 'tr') );
    if( insert_before_this ) {
      tr.parentNode.insertBefore(newnode, insert_before_this);
    } else {
      tr.parentNode.appendChild(newnode);
    }
  }

  update_bg( tr );

  $('save'+get_form_counter(tr)).style.visibility='';
  //Element.show( 'save'+get_form_counter(tr) );

  return false;
}

function xdelete( o ) {
  o.blur();
  var tr=find_parent_by_tag( o, 'tr' );
  var form=find_parent_by_tag( tr, 'form' );
  var parent=tr.parentNode;

  var hidden=tr.getElementsByTagName("td")[0];
  var v=hidden.getAttribute("ADM_ID");
  if( v.length ) {		// need to delete from database
    var newnode=document.createElement('input');
    newnode.name=("delete_"+hidden.getAttribute("ADM_BLOCK")+"_"+
		  hidden.getAttribute("ADM_ORDER")+"_"+v);
    newnode.value=1;
    newnode.type="hidden";
    form.appendChild(newnode);
  }

  parent.removeChild(tr);

  update_bg( parent );

  $('save'+get_form_counter(parent)).style.visibility='';
  //Element.show( 'save'+get_form_counter(parent) );

  return false;
}

function check_key( key ) {
  var forms=document.getElementsByTagName('form');
  for( i=0; i<forms.length; i++ ) {
    var k=forms[i].newkey;
    if( k!=null && k.value==key ) return 1;
  }
  var divs=document.getElementsByTagName('div');
  for( i=0; i<divs.length; i++ ) {
    var k=divs[i].getAttribute("ADM_KEY");
    if( k==key ) return 1;
  }
  return 0;
}

function xnewkey( o, uri ) {
  o.blur();
  if( next_counter!=null ) {
    var key='newkey';
    for( var i=1; check_key(key); i++ ) key='newkey'+i;
    if( uri==null ) uri="subroutine";
    o=find_parent_by_tag(o, 'h2');

    var newnode=document.createElement('div');
    newnode.id='div'+next_counter;
    newnode.style.display='';
    newnode.setAttribute("ADM_KEY", key);
    newnode.setAttribute("ADM_URI", uri);

    newnode.innerHTML=
      ( '<div class="fetch">'+
	'<form new_element="1" id="form'+next_counter+'"'+
	'	  onsubmit="return false;"'+
	'	  ADM_COUNTER="'+next_counter+'"'+
	'	  ADM_NBLOCKS="1">'+
	'	<table>'+
	'		<tr>'+
	'			<td class="tdcol1">New Key:</td>'+
	'			<td class="tdcol2">'+
	'				<input type="text" name="newkey" id="key'+next_counter+'" value="'+key.escapeHTML()+'"'+
	'					   onchange="return xchanged( '+next_counter+' );"'+
	'					   onkeyup="return xchanged( '+next_counter+' );">'+
	'			</td>'+
	'		</tr>'+
	(uri==":PRE:"
	 ? ('		<input type="hidden" name="newuri" id="uri'+next_counter+'" value="'+uri.escapeHTML()+'">')
	 : ('		<tr>'+
	    '			<td class="tdcol1">New Uri:</td>'+
	    '			<td class="tdcol2">'+
	    '				<input type="text" name="newuri" id="uri'+next_counter+'" value="'+uri.escapeHTML()+'"'+
	    '					   onchange="return xchanged( '+next_counter+' );"'+
	    '					   onkeyup="return xchanged( '+next_counter+' );">'+
	    '			</td>'+
	    '		</tr>'))+
	'		<tr><th colspan="2"><br>Action</th></tr>'+
	'		<tr class="tdc">'+
	'			<td ADM_BLOCK="0" ADM_ORDER="" ADM_ID=""'+
	'				colspan="2" class="tdc1">'+
	'				<textarea class="fetch_ta" rows="1" wrap="off"'+
	'						  onchange="return xchanged( '+next_counter+' );"'+
	'						  onkeyup="return xchanged( '+next_counter+' );"></textarea><br>'+
	'				<div class="resizer" name="resizer" title="resize text area above"></div>'+
	'			</td>'+
	'			<td class="control">'+
	'				&nbsp;<a href="#" onclick="return xinsert(this, -1);"'+
	'						 title="new action above"><img src="1uparrow.gif"></a>'+
	'				<br>'+
	'				&nbsp;<a href="#" onclick="return xinsert(this, 1);"'+
	'						 title="new action below"><img src="1downarrow.gif"></a>'+
	'			</td>'+
	'			<td class="control">'+
	'				&nbsp;<a href="#" onclick="return xbinsert(this, -1);"'+
	'						 title="new block above"><img src="2uparrow.gif"></a>'+
	'				<br>'+
	'				&nbsp;<a href="#" onclick="return xbinsert(this, 1);"'+
	'						 title="new block below"><img src="2downarrow.gif"></a>'+
	'			</td>'+
	'			<td class="control">'+
	'				&nbsp;<a href="#" onclick="return xdelete(this, 1);"'+
	'						 title="delete action"><img src="delete.gif"></a>'+
	'			</td>'+
	'		</tr>'+
	'	</table>'+
	'</form>'+
	'</div>' );

    add_resizer( newnode );

    if( o.nextSibling ) {
      o.parentNode.insertBefore( newnode, o.nextSibling );
    } else {
      o.parentNode.appendChild( newnode );
    }

    newnode=document.createElement('h3');
    newnode.innerHTML=
      ( '<a id="a'+next_counter+'" class="opener" href="#"'+
	'   title="open/close this block list"'+
	'   onclick="return xtoggle( '+next_counter+', this )">'+opener[2]+
	'</a>'+
	'<a href="#" class="opener" id="reload'+next_counter+'"'+
	'   title="reload this block list"'+
	'   onclick="return xreload( '+next_counter+', this );"'+
	'   style="visibility: hidden;">'+
	'	<img src="reload.gif">'+
	'</a>'+
	'<a href="#" class="opener" id="save'+next_counter+'"'+
	'   title="save this block list"'+
	'   onclick="return xupdate( '+next_counter+', this );"'+
	'   style="visibility: hidden;">'+
	'	<img src="save.gif">'+
	'</a>'+
	'<span class="header" id="header'+next_counter+'"></span>');

    o.parentNode.insertBefore( newnode, o.nextSibling );
    update_header(next_counter, key, uri);

    next_counter++;
  }
  return false;
}
