require 'mongo'
# ugly patch to avoid errors in to_json
class BSON::Binary
  def to_json(*a)
    str = self.to_s
    begin
      begin
        str = str.to_json(*a)
      rescue Encoding::UndefinedConversionError
        str = '0x'+str.unpack('H*').first
      end
      if str.length > 100
        str = str[0..100]+'...'
      end
      return str.to_json(*a)
    rescue => e
      return "[Binary Data Error: #{e.message}]".to_json(*a)
    end
  end
end
# another ugly patch to present bson id's as strings
class BSON::ObjectId
  def to_json(*a)
    "ObjectId('#{self.to_s}')".to_json(*a)
  end
end
# the data-event-handler:
class MongoTool < GUIPlugin
  def is_connected?( conn )
    if conn.class == Mongo::DB
      return conn.connection.active?
    else
      return false
    end
  end
  def load_ses( session )
    ses = get_ses( session )
    if ses.has_key?(:conn) and ses[:conn] == true
      conn = create_conn( ses )
      if conn
        ses[:conn] = conn
      else
        ses.delete(:conn)
      end
    end
  end
  def restore_ses( msg )
    super
    ses = get_ses( msg )
    if ses.has_key?( :conn ) and ses[:conn].class == Mongo::DB
      set_document_values( msg )
    end
  end
  def dump_ses( session )
    ses = get_ses( session )
    if ses.has_key?(:conn)
      if is_connected?( ses[:conn] )
        disconnect( ses )
        ses[:conn] = true
      else
        ses.delete( :conn )
      end
    end
  end
  def expire_ses( session )
    ses = get_ses( session )
    disconnect( ses )
  end
  def expire_ses_id( ses_id )
  end
  def disconnect( ses )
    if ses.has_key?(:conn) and ses[:conn] != true
      ses[:conn].logout
      ses.delete(:conn)
    end
  end
  def coll_list( msg )
    get_ses( msg, :conn ).collection_names.sort
  end
  def refresh_collections( msg )
    get_ses( msg, :collections ).set( msg, coll_list( msg ) )
  end
  def get_conn( msg )
    ses = get_ses( msg )
    if ses[:conn].class != Mongo::DB
      conn = create_conn( ses )
      if conn.class == String
        set_error( msg, conn )
        return false
      end
      ses[:conn] = conn
    end
    return ses[:conn]
  end
  def get_coll( msg )
    conn = get_conn( msg )
    return false unless conn
    ses = get_ses( msg )
    coll_name = ses[:selected_collection].data
    coll = conn.collection(coll_name)
    return coll
  end
  def select_documents( msg )
    ses = get_ses( msg )
    coll = get_coll( msg )
    per_page = ses[:documents_per_page].data
    page = ses[:documents_page].data
    start_index = (page-1)*per_page
    cursor = coll.find({})
    cursor.skip( start_index ) unless start_index <= 0
    documents = []
    per_page.times do
      break unless cursor.has_next?
      documents.push( cursor.next )
    end
    cursor.close
    ses[:documents].set( msg, documents )
  end
  def set_document_values( msg, value=nil )
    ses = get_ses( msg )
    coll = get_coll( msg )
    return false unless coll
    documents_count = coll.count
    ses[:documents_count].set( msg, documents_count )
    documents_per_page = ses[:documents_per_page].data
    documents_pages = ( documents_count.to_f / documents_per_page ).ceil
    ses[:documents_pages].set( msg, documents_pages )
    if ses[:documents_page].data > documents_pages
      ses[:documents_page].set( msg, documents_pages )
    end
    if documents_count == 0
      ses[:documents].set( msg, [] )
    else
      select_documents( msg )
    end
    true
  end
  def select_collection( msg, value )
    coll_name = value.data
    unless coll_list( msg ).include?( coll_name )
      value.set( msg, coll_list( msg ).first )
    end
    set_document_values( msg )
    true
  end
  def idle( msg )
    ses = get_ses( msg )
    if ses[:conn] == true
      ses[:conn] = create_conn( ses )
    elsif ses.has_key?(:setup_show) and not is_connected?( ses[:conn] )
      ses[:setup_show].set( msg, true )
    elsif is_connected?( ses[:conn] )
      refresh_collections( msg )
    end
  end
  def show_setup?( msg )
    ses = get_ses( msg )
    return false if ses.has_key?( :conn ) and is_connected?( ses[:conn] )
    return true
  end
  def set_error( msg, err_data=false )
    ses = get_ses( msg )
    if err_data == false
      ses[:err_msg_show].set( msg, -1 )
      ses[:err_msg_data].set( msg, '' )
    else
      ses[:err_msg_show].set( msg, 0 )
      ses[:err_msg_data].set( msg, err_data )
    end
  end
  def hide_setup( msg )
    get_ses( msg, :setup_show ).set( msg, false )
  end
  def create_conn( ses )
    ( user, pass, host, port, db ) = [:user,:pass,:host,:port,:database].map do |key|
      ses[key].data
    end
    begin
      conn = Mongo::Connection.new( host, port ).db( db )
    rescue Mongo::ConnectionFailure => e
      return e.message
    rescue => e
      return "Unhandled error:\n#{e.message}"
    end
    auth = conn.authenticate( user, pass, true )
    return "Invalid credentials" unless auth
    return conn
  end
  def connect( msg, value )
    if value.data == 1
      ses = get_ses( msg )
      conn = create_conn( ses )
      if conn.class == String
        set_error( msg, conn )
      else
        ses[:conn] = conn
        hide_setup( msg )
        select_collection( msg, ses[:selected_collection] )
      end
      value.set( msg, 0 )
    end
    true
  end
end
